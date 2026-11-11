#!/usr/bin/env bash
# ClearPay ledger on a two-node PostgreSQL cluster: streaming replication, replica lag,
# synchronous vs asynchronous commit, the availability cost of synchronous replication,
# failover, and rejoining the old primary with pg_rewind.
#
# Usage: ./pg_replication.sh      (output also saved to evidence/pg-replication.txt)
# Creates .cluster/pg/ (git-ignored), uses ports 55432 and 55433, and stops both
# servers at the end. Trust authentication on 127.0.0.1 is for this local demo only.
set -euo pipefail
cd "$(dirname "$0")"
PGBIN=${PGBIN:-/usr/local/opt/postgresql@15/bin}
ROOT=.cluster/pg
N1=55432   # node1: starts as primary
N2=55433   # node2: starts as replica
P1=../portfolio-1-database-design
P3=../portfolio-3-transactions-concurrency
mkdir -p evidence
exec > >(tee evidence/pg-replication.txt) 2>&1

section() { printf '\n=== %s\n' "$1"; }
say() { printf -- '--- %s\n' "$1"; }
# Expected errors (such as writing to the standby) are part of the evidence, so they do not stop the script.
sql() { local port=$1; shift; "$PGBIN/psql" -X -h 127.0.0.1 -p "$port" -U postgres -d clearpay -v SHOW_CONTEXT=never "$@" || true; }
balances() {
    sql "$1" -c "SELECT '$2' AS node, account_number, balance FROM customer_account_balance
                  WHERE account_number IN ('0012345601', '0012345602') ORDER BY 2"
}
stop_all() {
    for d in node1 node2; do
        [[ -f $ROOT/$d/postmaster.pid ]] && "$PGBIN/pg_ctl" -D "$ROOT/$d" -m fast stop >/dev/null 2>&1 || true
    done
}
trap stop_all EXIT

section "0. Build the cluster"
stop_all
rm -rf "$ROOT" && mkdir -p "$ROOT"
"$PGBIN/initdb" -D "$ROOT/node1" -U postgres --auth=trust --data-checksums -E UTF8 --locale=C >/dev/null
cat >> "$ROOT/node1/postgresql.conf" <<EOF
port = $N1
listen_addresses = '127.0.0.1'
unix_socket_directories = ''
cluster_name = 'node1'
wal_level = replica
max_wal_senders = 5
max_replication_slots = 5
hot_standby = on
EOF
"$PGBIN/pg_ctl" -D "$ROOT/node1" -l "$ROOT/node1.log" -w start >/dev/null
"$PGBIN/createdb" -h 127.0.0.1 -p $N1 -U postgres clearpay
for f in "$P1/schema.sql" "$P3/01_procedures.sql" "$P3/02_fixture.sql"; do
    "$PGBIN/psql" -X -q -h 127.0.0.1 -p $N1 -U postgres -d clearpay -v ON_ERROR_STOP=1 -f "$f" >/dev/null
done
say "node1 loaded with the Portfolio 1 schema, the Portfolio 3 procedures and fixture"

# Physical copy of node1 + standby.signal + primary_conninfo (-R), with a replication
# slot (-C -S) so that node1 keeps the WAL node2 has not received yet.
"$PGBIN/pg_basebackup" -h 127.0.0.1 -p $N1 -U postgres -D "$ROOT/node2" -X stream -R -C -S node2_slot --checkpoint=fast
printf "port = %s\ncluster_name = 'node2'\n" $N2 >> "$ROOT/node2/postgresql.conf"
"$PGBIN/pg_ctl" -D "$ROOT/node2" -l "$ROOT/node2.log" -w start >/dev/null
say "node2 created with pg_basebackup and started as a hot standby"
sleep 1

section "1. Replication status"
say "node1: connected standbys"
sql $N1 -c "SELECT application_name, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication"
say "node2: is it a standby, and where does it stream from?"
sql $N2 -c "SELECT pg_is_in_recovery() AS standby, status, sender_host, sender_port, slot_name FROM pg_stat_wal_receiver"

section "2. A transfer committed on node1 appears on node2"
sql $N1 -c "SELECT post_transfer('p5-req-1', 'P5-TRF-1', '0012345601', '0012345602', 5000, 'amina.mobile-app') IS NOT NULL AS posted"
sleep 0.5
balances $N1 node1
balances $N2 node2

section "3. The standby is read-only"
sql $N2 -c "SHOW transaction_read_only"
sql $N2 -c "SELECT post_transfer('p5-req-x', 'P5-TRF-X', '0012345601', '0012345602', 1, 'amina.mobile-app')"

section "4. Asynchronous replication: a lagging standby serves a stale balance"
say "node2 replay is paused, to stand in for a standby that is behind (slow disk or network)"
sql $N2 -At -c "SELECT pg_wal_replay_pause()" >/dev/null
sql $N1 -c "SELECT post_transfer('p5-req-2', 'P5-TRF-2', '0012345601', '0012345602', 1000, 'amina.mobile-app') IS NOT NULL AS posted"
say "COMMIT returned on node1. Amina's app now reads from node2:"
balances $N1 node1
balances $N2 node2
sql $N1 -c "SELECT application_name, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_not_yet_applied FROM pg_stat_replication"
say "replay resumed"
sql $N2 -At -c "SELECT pg_wal_replay_resume()" >/dev/null
sleep 0.5
balances $N2 node2

section "5. Commit latency: asynchronous vs synchronous replication (pgbench, 500 single-deposit transactions each)"
cat > "$ROOT/deposit.sql" <<'EOF'
SELECT post_deposit('pgb-' || gen_random_uuid(), 'PGB-' || gen_random_uuid(), '0012345603', 1, 'pgbench');
EOF
bench() {  # $1 = label, $2 = synchronous_standby_names, $3 = synchronous_commit
    sql $N1 -q -c "ALTER SYSTEM SET synchronous_standby_names = '$2'" -c "SELECT pg_reload_conf()" >/dev/null
    sleep 0.5
    local result
    result=$(PGOPTIONS="-c synchronous_commit=$3" "$PGBIN/pgbench" -n -h 127.0.0.1 -p $N1 -U postgres \
             -f "$ROOT/deposit.sql" -t 500 -c 1 clearpay 2>&1 | grep -E "latency average|tps")
    printf '%-58s %s\n' "$1" "$(echo "$result" | tr '\n' ' ')"
}
bench "async standby, synchronous_commit=on (local flush)"        ""      on
bench "sync standby,  synchronous_commit=remote_write"             "node2" remote_write
bench "sync standby,  synchronous_commit=on (standby flush)"       "node2" on
bench "sync standby,  synchronous_commit=remote_apply (visible)"   "node2" remote_apply
sql $N1 -c "SELECT application_name, sync_state FROM pg_stat_replication"

section "6. Synchronous replication with the standby down: commits wait (consistency over availability)"
say "node2 stopped; node1 still requires node2 to confirm every commit"
"$PGBIN/pg_ctl" -D "$ROOT/node2" -m fast stop >/dev/null
( sql $N1 -c "SELECT post_transfer('p5-req-3', 'P5-TRF-3', '0012345601', '0012345602', 500, 'amina.mobile-app') IS NOT NULL AS posted" \
      > "$ROOT/blocked.txt" 2>&1 ) &
BLOCKED=$!
sleep 3
say "3 seconds later, the client is still waiting:"
sql $N1 -c "SELECT pid, state, wait_event_type, wait_event, now() - xact_start AS waiting_for, left(query, 40) AS query
              FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
say "an operator cancels the wait"
sql $N1 -At -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep'" >/dev/null
wait $BLOCKED || true
say "what the client received:"
cat "$ROOT/blocked.txt"
say "the transfer is nevertheless committed on node1:"
sql $N1 -c "SELECT reference, status FROM financial_transaction WHERE reference = 'P5-TRF-3'"
"$PGBIN/pg_ctl" -D "$ROOT/node2" -l "$ROOT/node2.log" -w start >/dev/null
sleep 1
say "node2 restarted and caught up:"
sql $N2 -c "SELECT reference, status FROM financial_transaction WHERE reference = 'P5-TRF-3'"

section "7. Failover: node1 crashes, node2 is promoted"
sql $N1 -c "SELECT post_transfer('p5-req-4', 'P5-TRF-4', '0012345601', '0012345602', 250, 'amina.mobile-app') IS NOT NULL AS posted"
say "state on node1 just before the crash (synchronous replication is on, so node2 has every commit)"
sql $N1 -c "SELECT count(*) AS transactions, sum(amount) AS total_amount, max(reference) FILTER (WHERE reference LIKE 'P5-%') AS last_p5 FROM financial_transaction"
balances $N1 node1
T0=$(python3 -c 'import time; print(time.time())')
"$PGBIN/pg_ctl" -D "$ROOT/node1" -m immediate stop >/dev/null
say "node1 killed (pg_ctl stop -m immediate: no shutdown checkpoint, as in a crash)"
sql $N2 -c "SELECT post_transfer('p5-req-5', 'P5-TRF-5', '0012345601', '0012345602', 100, 'amina.mobile-app')"
say "promote node2"
sql $N2 -c "SELECT pg_promote(wait => true) AS promoted"
T1=$(python3 -c 'import time; print(time.time())')
printf 'crash to writable primary: %.2f s (excluding failure detection, which an operator or tool such as Patroni would add)\n' \
       "$(python3 -c "print($T1 - $T0)")"
# Promotion requests its checkpoint in the background. Until it completes, the control
# file still shows timeline 1, and pg_rewind (section 8) would wrongly see no divergence.
sql $N2 -q -c "CHECKPOINT"
sql $N2 -c "SELECT pg_is_in_recovery() AS standby, timeline_id FROM pg_control_checkpoint()"
say "node2 has every transaction node1 had (RPO = 0):"
sql $N2 -c "SELECT count(*) AS transactions, sum(amount) AS total_amount, max(reference) FILTER (WHERE reference LIKE 'P5-%') AS last_p5 FROM financial_transaction"
balances $N2 node2
say "node2 accepts writes"
sql $N2 -c "SELECT post_transfer('p5-req-5', 'P5-TRF-5', '0012345601', '0012345602', 100, 'amina.mobile-app') IS NOT NULL AS posted"

section "8. The old primary rejoins as a standby (pg_rewind)"
say "node1 must not start as a primary again (split brain). pg_rewind discards its divergent WAL:"
"$PGBIN/pg_rewind" --target-pgdata="$ROOT/node1" --source-server="host=127.0.0.1 port=$N2 user=postgres dbname=postgres" 2>&1 \
    | grep '^pg_rewind:' || true
# pg_rewind also copies node2's configuration files, including its port, name and slot
# setting. node1's own identity is restored, and it is pointed at node2 as its primary.
touch "$ROOT/node1/standby.signal"
printf "port = %s\ncluster_name = 'node1'\n" $N1 >> "$ROOT/node1/postgresql.conf"
cat >> "$ROOT/node1/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=127.0.0.1 port=$N2 user=postgres'
primary_slot_name = ''
EOF
"$PGBIN/pg_ctl" -D "$ROOT/node1" -l "$ROOT/node1.log" -w start >/dev/null
sleep 2
say "node2 (new primary): connected standbys"
sql $N2 -c "SELECT application_name, state, sync_state FROM pg_stat_replication"
say "node1 (now a standby) has P5-TRF-5, which was written after the failover:"
sql $N1 -c "SELECT pg_is_in_recovery() AS standby, (SELECT status FROM financial_transaction WHERE reference = 'P5-TRF-5') AS p5_trf_5"
