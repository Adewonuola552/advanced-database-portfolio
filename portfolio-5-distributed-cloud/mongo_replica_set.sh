#!/usr/bin/env bash
# ClearPay MongoDB on a three-member replica set: replication, write concern, a stale
# secondary read, automatic failover under a running client, and loss of majority.
#
# Usage: ./mongo_replica_set.sh   (output also saved to evidence/mongo-replica-set.txt)
# Creates .cluster/rs/ (git-ignored), uses ports 27201-27203, and stops all members at the end.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=.cluster/rs
PORTS=(27201 27202 27203)
URI="mongodb://127.0.0.1:27201,127.0.0.1:27202,127.0.0.1:27203/clearpay?replicaSet=clearpay-ha"
mkdir -p evidence
exec > >(tee evidence/mongo-replica-set.txt) 2>&1

section() { printf '\n=== %s\n' "$1"; }
say() { printf -- '--- %s\n' "$1"; }
js() { mongosh --quiet "$@"; }
start_member() {  # $1 = member number 1-3
    local port=${PORTS[$(($1 - 1))]}
    mkdir -p "$ROOT/n$1"
    mongod --replSet clearpay-ha --port "$port" --bind_ip 127.0.0.1 --dbpath "$ROOT/n$1" \
           --wiredTigerCacheSizeGB 0.25 --fork --logpath "$ROOT/n$1.log" >/dev/null
}
kill_member() {  # $1 = member number; SIGKILL, as in a crash
    pkill -9 -f "mongod --replSet clearpay-ha --port ${PORTS[$(($1 - 1))]}" || true
}
stop_all() { for i in 1 2 3; do kill_member "$i"; done; }
members() {  # one line per member, from whichever member answers on $1
    js --port "$1" --eval '
        rs.status().members.forEach((m) => print(`    ${m.name}  ${m.stateStr.padEnd(10)}  health ${m.health}` +
            (m.syncSourceHost ? `  syncing from ${m.syncSourceHost}` : "")))'
}
trap stop_all EXIT

section "0. Start three members and initiate the replica set"
stop_all; sleep 1
rm -rf "$ROOT"
for i in 1 2 3; do start_member $i; done
js --port 27201 --eval '
rs.initiate({ _id: "clearpay-ha", members: [
    { _id: 0, host: "127.0.0.1:27201", priority: 2 },   // preferred primary (e.g. the main data centre)
    { _id: 1, host: "127.0.0.1:27202", priority: 1 },
    { _id: 2, host: "127.0.0.1:27203", priority: 1 } ] });
while (!db.hello().isWritablePrimary) sleep(200);
const c = rs.conf();
print(`replica set ${c._id}: ${c.members.length} voting members, majority = ${Math.floor(c.members.length / 2) + 1}, ` +
      `electionTimeoutMillis = ${c.settings.electionTimeoutMillis}`);'
sleep 2
members 27201

section "1. Load ClearPay accounts and write with different write concerns"
js "$URI" --eval '
db.accounts.insertMany([
  { accountNumber: "0012345601", owner: "Amina Bello", balance: NumberDecimal("20000") },
  { accountNumber: "0012345602", owner: "Tunde Okoro", balance: NumberDecimal("5000") } ],
  { writeConcern: { w: "majority" } });
for (const w of [1, "majority", 3]) {
  const t = Date.now();
  for (let i = 0; i < 300; i++)
    db.ledger_events.insertOne({ seq: i, w: String(w), at: new Date() }, { writeConcern: { w, j: true } });
  print(`  300 inserts with { w: ${JSON.stringify(w)}, j: true }: ${((Date.now() - t) / 300).toFixed(2)} ms per write`);
}'

section "2. A secondary that falls behind serves stale reads"
say "27203 is locked with fsyncLock, so it stops applying replicated writes (a slow or overloaded secondary)"
js --port 27203 --eval 'db.fsyncLock(); print("    27203 locked")'
js "$URI" --eval '
const r = db.accounts.updateOne({ accountNumber: "0012345601" }, { $inc: { balance: NumberDecimal("-5000") } },
                                { writeConcern: { w: "majority", wtimeout: 5000 } });
print(`  primary: debit of 5,000 acknowledged by a majority (primary + 27202): modified ${r.modifiedCount}`);'
for p in 27201 27202 27203; do
    js --port $p --eval "
db.getMongo().setReadPref('primaryPreferred');
const a = db.getSiblingDB('clearpay').accounts.findOne({ accountNumber: '0012345601' });
print('  read on $p (' + (db.hello().isWritablePrimary ? 'primary' : 'secondary') + '): Amina balance ' + a.balance)"
done
say "a write that needs all three members cannot be acknowledged while 27203 is behind"
js "$URI" --eval '
try {
  db.accounts.updateOne({ accountNumber: "0012345602" }, { $inc: { balance: NumberDecimal("1") } },
                        { writeConcern: { w: 3, wtimeout: 2000 } });
} catch (e) { print("  w: 3 -> " + e.codeName + ": " + e.message.split("\n")[0]); }'
js --port 27203 --eval 'db.fsyncUnlock(); print("    27203 unlocked")'
sleep 1
js --port 27203 --eval "
db.getMongo().setReadPref('secondary');
print('  read on 27203 after it caught up: Amina balance ' + db.getSiblingDB('clearpay').accounts.findOne({ accountNumber: '0012345601' }).balance)"

section "3. Failover: the primary crashes while a client is writing"
say "the client posts one ledger event every 100 ms with { w: majority } and retryable writes"
js "$URI&retryWrites=true&serverSelectionTimeoutMS=30000" --eval '
const end = Date.now() + 28000, log = [];
let seq = 0;
while (Date.now() < end) {
  const t = Date.now();
  try {
    db.failover_events.insertOne({ seq: seq++, at: new Date() }, { writeConcern: { w: "majority" } });
    log.push({ t, ms: Date.now() - t, ok: true });
  } catch (e) { log.push({ t, ms: Date.now() - t, ok: false, err: e.codeName || e.message }); }
  sleep(100);
}
const slow = log.filter((l) => !l.ok || l.ms > 500);
print(`  client: ${log.length} writes attempted, ${log.filter((l) => l.ok).length} succeeded, ${log.filter((l) => !l.ok).length} failed`);
slow.forEach((l) => print(`  client: write at ${new Date(l.t).toISOString().slice(11, 23)} UTC took ${l.ms} ms ` +
                          (l.ok ? "and succeeded (held until a new primary was elected)" : "and failed: " + l.err)));
print(`  client: documents stored = ${db.failover_events.countDocuments()} (no write lost or duplicated: seq is unique = ` +
      `${db.failover_events.distinct("seq").length === db.failover_events.countDocuments()})`);
' > "$ROOT/client.txt" 2>&1 &
CLIENT=$!
sleep 4
T0=$(python3 -c 'import time; print(time.time())')
kill_member 1
printf '    %s UTC  27201 (primary) killed with SIGKILL\n' "$(date -u +%H:%M:%S)"
until js "mongodb://127.0.0.1:27202,127.0.0.1:27203/?replicaSet=clearpay-ha&serverSelectionTimeoutMS=500" \
         --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; do sleep 0.2; done
T1=$(python3 -c 'import time; print(time.time())')
printf '    %s UTC  new primary elected: %.1f s after the crash\n' "$(date -u +%H:%M:%S)" "$(python3 -c "print($T1 - $T0)")"
members 27202
wait $CLIENT || true
cat "$ROOT/client.txt"

section "4. The old primary returns"
start_member 1
say "27201 restarts, rejoins as a secondary, catches up, and (priority 2) takes over as primary again"
sleep 15
members 27201

section "5. Loss of majority: two of three members down"
kill_member 2; kill_member 3
say "27202 and 27203 killed; 27201 can see only itself (1 of 3 votes, majority is 2)"
sleep 12
members 27201
js --port 27201 --eval '
try { db.getSiblingDB("clearpay").accounts.updateOne({ accountNumber: "0012345601" }, { $inc: { balance: NumberDecimal("-1") } }); }
catch (e) { print("  write: " + e.codeName + ": " + e.message.split("\n")[0]); }
db.getMongo().setReadPref("secondaryPreferred");
print("  read with readPreference secondaryPreferred still works: Amina balance " +
      db.getSiblingDB("clearpay").accounts.findOne({ accountNumber: "0012345601" }).balance);'
start_member 2
say "27202 back: two of three members, a majority again"
js --port 27201 --eval 'while (!rs.status().members.some((m) => m.stateStr === "PRIMARY")) sleep(500)'
members 27201
