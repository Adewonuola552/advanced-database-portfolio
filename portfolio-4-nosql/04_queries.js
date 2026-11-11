// ClearPay read patterns on the MongoDB model, with execution plans.
// Usage: mongosh --quiet "mongodb://127.0.0.1:27117/clearpay?replicaSet=clearpay-rs" 04_queries.js
// Run after the import and before 03_operations.js (run_all.sh does this).

db = db.getSiblingDB("clearpay");
const RUNS = 5;

function heading(text) { print("\n=== " + text); }

// Stage names from the winning plan, and the work counters from executionStats.
function plan(explain) {
  const names = [];
  (function walk(s) {
    if (!s) return;
    names.push(s.stage + (s.indexName ? `(${s.indexName})` : ""));
    walk(s.inputStage);
    (s.inputStages || []).forEach(walk);
  })(explain.queryPlanner.winningPlan.queryPlan || explain.queryPlanner.winningPlan);
  const es = explain.executionStats;
  return `plan ${names.join(" <- ")}\n      returned ${es.nReturned}, index keys examined ${es.totalKeysExamined}, ` +
         `documents examined ${es.totalDocsExamined}, server time ${es.executionTimeMillis} ms`;
}
// Median wall-clock time over RUNS runs, after one warm-up run.
function median(fn) {
  fn();
  const times = [];
  for (let i = 0; i < RUNS; i++) { const t = Date.now(); fn(); times.push(Date.now() - t); }
  times.sort((a, b) => a - b);
  return times[Math.floor(RUNS / 2)];
}

// --------------------------------------------------------------------------------------
heading("Collection sizes after import");
db.adminCommand({ fsync: 1 }); // flush to disk so that storage sizes are complete
print("  collection      documents  avg doc bytes  storage MB  index MB");
for (const name of ["customers", "accounts", "transactions", "audit_events"]) {
  const s = db.getCollection(name).stats({ scale: 1024 * 1024 });
  const count = db.getCollection(name).countDocuments();
  print(`  ${name.padEnd(14)} ${String(count).padStart(10)}  ${String(s.avgObjSize || "-").padStart(13)}  ` +
        `${String(s.storageSize).padStart(10)}  ${String(s.totalIndexSize).padStart(8)}`);
}

// --------------------------------------------------------------------------------------
heading("Q1. Customer profile with accounts: one document, no join");
const q1 = { email: "customer00001@example.com" };
print("  " + plan(db.customers.find(q1).explain("executionStats")));
printjson(db.customers.findOne(q1, { _id: 0, firstName: 1, lastName: 1, email: 1, accounts: 1 }));

// --------------------------------------------------------------------------------------
heading("Q2. Account statement: latest 20 posted transactions for one account");
const hot = db.accounts.findOne({ accountNumber: "0000000001" });   // busiest account
const typical = db.accounts.findOne({ accountNumber: "0000020001" });
for (const a of [hot, typical]) {
  print(`  ${a.accountNumber}: ${db.transactions.countDocuments({ "entries.accountId": a._id, status: "POSTED" })} posted transactions`);
}
const statement = (id) => db.transactions.find({ "entries.accountId": id, status: "POSTED" }).sort({ postedAt: -1 }).limit(20);

print("\n  BEFORE the index:");
for (const a of [hot, typical]) {
  print(`    ${a.accountNumber}: median ${median(() => statement(a._id).toArray())} ms over ${RUNS} runs`);
  print("      " + plan(statement(a._id).explain("executionStats")));
}

// Equality fields first, then the sort field (the ESR rule: Equality, Sort, Range).
// entries is an array, so this is a multikey index: one key per leg.
let t = Date.now();
db.transactions.createIndex({ "entries.accountId": 1, status: 1, postedAt: -1 }, { name: "statement_idx" });
print(`\n  createIndex statement_idx: ${Date.now() - t} ms`);

print("\n  AFTER the index:");
for (const a of [hot, typical]) {
  print(`    ${a.accountNumber}: median ${median(() => statement(a._id).toArray())} ms over ${RUNS} runs`);
  print("      " + plan(statement(a._id).explain("executionStats")));
}

print("\n  First 5 lines of the statement for " + typical.accountNumber + ":");
db.transactions.aggregate([
  { $match: { "entries.accountId": typical._id, status: "POSTED" } },
  { $sort: { postedAt: -1 } },
  { $limit: 5 },
  { $project: { _id: 0, postedAt: 1, reference: 1, type: 1,
                leg: { $first: { $filter: { input: "$entries", cond: { $eq: ["$$this.accountId", typical._id] } } } } } },
]).forEach((r) => print(`    ${r.postedAt.toISOString().slice(0, 19)}  ${r.reference}  ${r.type.padEnd(10)}  ${r.leg.type.padEnd(6)}  ${r.leg.amount}`));

// --------------------------------------------------------------------------------------
heading("Q3. Monthly posted volume by type, NGN, 2026 (analytics)");
const q3 = [
  { $match: { status: "POSTED", currency: "NGN", postedAt: { $gte: ISODate("2026-01-01"), $lt: ISODate("2027-01-01") } } },
  { $group: { _id: { month: { $dateToString: { format: "%Y-%m", date: "$postedAt" } }, type: "$type" },
              count: { $sum: 1 }, amount: { $sum: "$amount" } } },
  { $sort: { "_id.month": 1, "_id.type": 1 } },
];
print(`  median ${median(() => db.transactions.aggregate(q3).toArray())} ms over ${RUNS} runs (full collection scan; ` +
      "a reporting query like this belongs on a secondary, see Portfolio 5)");
db.transactions.aggregate(q3).toArray().filter((r) => r._id.month <= "2026-03")
  .forEach((r) => print(`    ${r._id.month}  ${r._id.type.padEnd(10)}  ${String(r.count).padStart(6)}  ${r.amount}`));
print("    ... (first three months shown)");

// --------------------------------------------------------------------------------------
heading("Q4. Graph: where did money from one account go? ($graphLookup over transfer links)");
t = Date.now();
db.transfer_links.drop();
db.transactions.aggregate([
  { $match: { type: "TRANSFER", status: "POSTED" } },
  { $project: { amount: 1,
                from: { $first: { $filter: { input: "$entries", cond: { $eq: ["$$this.type", "DEBIT"] } } } },
                to: { $first: { $filter: { input: "$entries", cond: { $eq: ["$$this.type", "CREDIT"] } } } } } },
  { $group: { _id: { from: "$from.accountNumber", to: "$to.accountNumber" }, transfers: { $sum: 1 }, total: { $sum: "$amount" } } },
  { $project: { from: "$_id.from", to: "$_id.to", transfers: 1, total: 1 } },
  { $merge: { into: "transfer_links", whenMatched: "replace" } },
]);
db.transfer_links.createIndex({ from: 1 });
print(`  Built ${db.transfer_links.countDocuments()} account-to-account edges from posted transfers in ${Date.now() - t} ms`);
print("  One edge: " + JSON.stringify(db.transfer_links.findOne({}, { _id: 0 })));

const flagged = "0000020001";
const threshold = NumberDecimal("20000");
const q4 = [
  { $match: { accountNumber: flagged } },
  { $graphLookup: { from: "transfer_links", startWith: "$accountNumber", connectFromField: "to", connectToField: "from",
                    as: "flow", maxDepth: 2, depthField: "depth", restrictSearchWithMatch: { total: { $gte: threshold } } } },
  { $unwind: "$flow" },
  { $group: { _id: "$flow.depth", links: { $sum: 1 }, accounts: { $addToSet: "$flow.to" }, amount: { $sum: "$flow.total" } } },
  { $project: { _id: 0, hop: { $add: ["$_id", 1] }, links: 1, accountsReached: { $size: "$accounts" }, amount: 1 } },
  { $sort: { hop: 1 } },
];
print(`  Money trail from flagged account ${flagged}, following links that total at least ${threshold}, up to 3 hops:`);
print(`  median ${median(() => db.accounts.aggregate(q4).toArray())} ms over ${RUNS} runs`);
db.accounts.aggregate(q4).forEach((r) => print(`    hop ${r.hop}: ${String(r.links).padStart(5)} links, ${String(r.accountsReached).padStart(5)} accounts reached, ${r.amount} moved`));
print("  The first hop in detail:");
db.transfer_links.find({ from: flagged, total: { $gte: threshold } }, { _id: 0 }).sort({ total: -1 })
  .forEach((l) => print(`    ${l.from} -> ${l.to}  ${l.transfers} transfer(s), ${l.total}`));

// --------------------------------------------------------------------------------------
heading("Q5. Time-series: audit events per action per month (2026, finance officers)");
const q5 = [
  { $match: { "meta.actor": /^finance\./, at: { $gte: ISODate("2026-01-01"), $lt: ISODate("2027-01-01") } } },
  { $group: { _id: { month: { $dateToString: { format: "%Y-%m", date: "$at" } }, action: "$meta.action" }, events: { $sum: 1 } } },
  { $sort: { "_id.month": 1 } },
];
print(`  median ${median(() => db.audit_events.aggregate(q5).toArray())} ms over ${RUNS} runs`);
db.audit_events.aggregate(q5).toArray().slice(0, 4).forEach((r) => print(`    ${r._id.month}  ${r._id.action}  ${r.events}`));

print("\n  Storage: the same 100,000 events stored three ways");
const ts = { timeField: "at", metaField: "meta", granularity: "hours" };
["audit_ts_random", "audit_plain"].forEach((c) => db.getCollection(c).drop());
// _id is a random UUID, so sorting by it gives a random time order
// ($out cannot create a time-series collection in 7.0.2, so the copy is inserted directly)
db.createCollection("audit_ts_random", { timeseries: ts });
db.audit_ts_random.insertMany(db.audit_events.aggregate([{ $sort: { _id: 1 } }]).toArray());
db.audit_events.aggregate([{ $out: "audit_plain" }]);
db.adminCommand({ fsync: 1 });
for (const [name, label] of [["audit_events", "time-series, inserted in time order"],
                             ["audit_ts_random", "time-series, inserted in random order"],
                             ["audit_plain", "regular collection"]]) {
  const s = db.getCollection(name).stats({ scale: 1024 });
  print(`    ${label.padEnd(38)} storage ${String(s.storageSize).padStart(6)} KB` +
        (s.timeseries ? `   ${String(s.timeseries.bucketCount).padStart(6)} buckets` : ""));
}
["audit_ts_random", "audit_plain"].forEach((c) => db.getCollection(c).drop());
