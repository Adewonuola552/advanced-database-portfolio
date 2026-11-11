#!/usr/bin/env bash
# ClearPay MongoDB on a sharded cluster: two shards, a config server and a mongos router.
# Shows data distribution, targeted vs scatter-gather queries for different shard keys,
# and what happens when one shard is lost.
#
# Usage: ./mongo_sharding.sh [postgres-database]   (default clearpay_p2, as in Portfolio 4)
# Output also saved to evidence/mongo-sharding.txt. Creates .cluster/shard/ (git-ignored),
# uses ports 27300-27321, and stops everything at the end.
# Each shard is a one-member replica set to keep the demo small; production shards would
# each be a three-member replica set (see mongo_replica_set.sh).
set -euo pipefail
cd "$(dirname "$0")"
PGDB=${1:-clearpay_p2}
ROOT=.cluster/shard
MONGOS="mongodb://127.0.0.1:27300/clearpay"
mkdir -p evidence
exec > >(tee evidence/mongo-sharding.txt) 2>&1

section() { printf '\n=== %s\n' "$1"; }
say() { printf -- '--- %s\n' "$1"; }
js() { mongosh --quiet "$@"; }
stop_all() {
    pkill -9 -f "mongos --configdb cfg/127.0.0.1:27301" || true
    for p in 27301 27311 27321; do pkill -9 -f "mongod .*--port $p " || true; done
}
trap stop_all EXIT

section "0. Build the cluster"
stop_all; sleep 1
rm -rf "$ROOT"; mkdir -p "$ROOT"/{cfg,shard1,shard2,export}
mongod --configsvr --replSet cfg    --port 27301 --bind_ip 127.0.0.1 --dbpath "$ROOT/cfg"    --wiredTigerCacheSizeGB 0.25 --fork --logpath "$ROOT/cfg.log" >/dev/null
mongod --shardsvr  --replSet shard1 --port 27311 --bind_ip 127.0.0.1 --dbpath "$ROOT/shard1" --wiredTigerCacheSizeGB 0.5  --fork --logpath "$ROOT/shard1.log" >/dev/null
mongod --shardsvr  --replSet shard2 --port 27321 --bind_ip 127.0.0.1 --dbpath "$ROOT/shard2" --wiredTigerCacheSizeGB 0.5  --fork --logpath "$ROOT/shard2.log" >/dev/null
for rs in "cfg 27301" "shard1 27311" "shard2 27321"; do
    set -- $rs
    js --port "$2" --eval "rs.initiate({ _id: '$1', members: [{ _id: 0, host: '127.0.0.1:$2' }] });
                          while (!db.hello().isWritablePrimary) sleep(200)"
done
mongos --configdb cfg/127.0.0.1:27301 --port 27300 --bind_ip 127.0.0.1 --fork --logpath "$ROOT/mongos.log" >/dev/null
js "$MONGOS" --eval '
sh.addShard("shard1/127.0.0.1:27311");
sh.addShard("shard2/127.0.0.1:27321");
db.adminCommand({ listShards: 1 }).shards.forEach((s) => print(`  shard ${s._id}: ${s.host}`));
print("  router: mongos on 127.0.0.1:27300; config server replica set cfg on 127.0.0.1:27301");'

section "1. Shard the collections, then load the Portfolio 2 data through mongos"
js "$MONGOS" --eval '
sh.enableSharding("clearpay");
// Hashed keys spread inserts evenly and pre-split the collection across both shards.
sh.shardCollection("clearpay.accounts", { _id: "hashed" });
sh.shardCollection("clearpay.transactions", { _id: "hashed" });
// Statement lines: one document per ledger leg, sharded by account.
sh.shardCollection("clearpay.statement_lines", { accountId: "hashed" });
db.statement_lines.createIndex({ accountId: 1, postedAt: -1 });
db.accounts.createIndex({ accountNumber: 1 });
db.transactions.createIndex({ "entries.accountId": 1, status: 1, postedAt: -1 });
print("  accounts: { _id: hashed }   transactions: { _id: hashed }   statement_lines: { accountId: hashed }");'
psql -X -q -d "$PGDB" -v outdir="$ROOT/export" -f ../portfolio-4-nosql/01_export_from_postgres.sql >/dev/null
psql -X -q -d "$PGDB" -v outdir="$ROOT/export" -f statement_lines_export.sql
for c in accounts transactions statement_lines; do
    T0=$(python3 -c 'import time; print(time.time())')
    mongoimport --uri "$MONGOS" --collection $c --file "$ROOT/export/$c.json" --numInsertionWorkers 4 --quiet
    printf '  imported %-16s %8s documents in %5.1f s\n' "$c" "$(wc -l < "$ROOT/export/$c.json" | tr -d ' ')" \
           "$(python3 -c "import time; print(time.time() - $T0)")"
done

section "2. How the data is spread across the shards"
js "$MONGOS" --eval '
for (const c of ["accounts", "transactions", "statement_lines"]) {
  const per = {};
  db.getCollection(c).aggregate([{ $collStats: { storageStats: {} } }]).forEach((s) => per[s.shard] = s.storageStats.count);
  const chunks = db.getSiblingDB("config").chunks.aggregate([
    { $lookup: { from: "collections", localField: "uuid", foreignField: "uuid", as: "c" } },
    { $match: { "c._id": "clearpay." + c } }, { $group: { _id: "$shard", n: { $sum: 1 } } } ]).toArray();
  const total = Object.values(per).reduce((a, b) => a + b, 0);
  print(`  ${c.padEnd(16)} ` + Object.keys(per).sort().map((s) =>
    `${s}: ${String(per[s]).padStart(7)} docs (${(100 * per[s] / total).toFixed(1)}%), ` +
    `${chunks.find((x) => x._id === s)?.n ?? 0} chunks`).join("   "));
}'

section "3. Query routing: targeted vs scatter-gather"
js "$MONGOS" --eval '
function route(label, query) {   // query() returns a new cursor each time
  const e = query().explain("executionStats");
  const plan = e.queryPlanner.winningPlan;
  const shards = (e.executionStats.executionStages.shards || []);
  const docs = shards.reduce((a, s) => a + s.totalDocsExamined, 0);
  const keys = shards.reduce((a, s) => a + s.totalKeysExamined, 0);
  const runs = []; for (let i = 0; i < 6; i++) { const t = Date.now(); query().toArray(); runs.push(Date.now() - t); }
  runs.shift(); runs.sort((a, b) => a - b);
  print(`  ${label}`);
  print(`      ${plan.stage}: ${shards.length} shard(s) [${shards.map((s) => s.shardName).join(", ")}], ` +
        `${keys} keys and ${docs} documents examined, shards returned ${e.executionStats.nReturned}, median ${runs[2]} ms`);
}
const acct = db.accounts.findOne({ accountNumber: "0000000001" });
route("accounts by _id (the shard key)", () => db.accounts.find({ _id: acct._id }));
route("accounts by accountNumber (not the shard key)", () => db.accounts.find({ accountNumber: "0000000001" }));
const tx = db.transactions.findOne({ reference: "TXN00000001" });
route("transactions by _id (the shard key)", () => db.transactions.find({ _id: tx._id }));
route("statement from transactions, sharded by _id: latest 20 for account 0000000001",
      () => db.transactions.find({ "entries.accountId": acct._id, status: "POSTED" }).sort({ postedAt: -1 }).limit(20));
route("statement from statement_lines, sharded by accountId: latest 20 for account 0000000001",
      () => db.statement_lines.find({ accountId: acct._id }).sort({ postedAt: -1 }).limit(20));
route("monthly report over all transactions (any shard key: every shard has data)",
      () => db.transactions.find({ postedAt: { $gte: ISODate("2026-01-01"), $lt: ISODate("2026-02-01") } }));'

section "4. One shard fails"
say "before the failure: pick one account whose statement lines live on each shard"
eval "$(js "$MONGOS" --eval '
const hex = (u) => u.toString("hex").replace(/(.{8})(.{4})(.{4})(.{4})(.{12})/, "$1-$2-$3-$4-$5");
const found = {};
// Sorted by account number so the candidates come from both shards (an unsorted find can
// return documents from one shard only).
for (const a of db.accounts.find({ kind: "CUSTOMER" }).sort({ accountNumber: 1 }).limit(200).toArray()) {
  const shard = db.statement_lines.find({ accountId: a._id }).limit(1).explain("executionStats")
                  .executionStats.executionStages.shards[0].shardName;
  if (!found[shard]) found[shard] = a;
  if (found.shard1 && found.shard2) break;
}
for (const s of ["shard1", "shard2"]) print(`${s.toUpperCase()}_ID=${hex(found[s]._id)}; ${s.toUpperCase()}_NUM=${found[s].accountNumber}`);')"
echo "    account $SHARD1_NUM -> shard1, account $SHARD2_NUM -> shard2"
say "shard2 killed (SIGKILL). Each shard here has a single member, so its data is unavailable."
pkill -9 -f "mongod .*--port 27321 " || true
sleep 2
js "$MONGOS" --eval "
function attempt(label, fn) {
  try { print('  ' + label + ': OK, ' + fn()); }
  catch (e) { print('  ' + label + ': FAILED, ' + (e.codeName || e.name) + ': ' + e.message.split('\n')[0].slice(0, 100)); }
}
attempt('statement for $SHARD1_NUM (targeted to shard1, which is up)',
        () => db.statement_lines.find({ accountId: UUID('$SHARD1_ID') }).sort({ postedAt: -1 }).limit(20).toArray().length + ' lines');
attempt('statement for $SHARD2_NUM (targeted to shard2, which is down)',
        () => db.statement_lines.find({ accountId: UUID('$SHARD2_ID') }).sort({ postedAt: -1 }).limit(20).toArray().length + ' lines');
attempt('count all transactions (needs every shard)', () => db.transactions.countDocuments({}) + ' documents');
attempt('find all transactions with allowPartialResults',
        () => db.transactions.find({}, { _id: 1 }).allowPartialResults().batchSize(100000).toArray().length +
              ' documents returned (only the surviving shard)');"
