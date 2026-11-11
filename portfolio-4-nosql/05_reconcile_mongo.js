// Summary of the MongoDB copy, in the same line format as 05_reconcile_postgres.sql.
// With the argument "check", it instead recomputes every account balance from the
// embedded ledger legs and compares it with the stored balance.
db = db.getSiblingDB("clearpay");

if (typeof mode !== "undefined" && mode === "check") {
  const t0 = Date.now();
  const result = db.transactions.aggregate([
    { $match: { status: "POSTED" } },
    { $unwind: "$entries" },
    { $group: { _id: "$entries.accountId",
                fromLegs: { $sum: { $cond: [{ $eq: ["$entries.type", "CREDIT"] }, "$entries.amount",
                                            { $multiply: ["$entries.amount", -1] }] } } } },
    { $lookup: { from: "accounts", localField: "_id", foreignField: "_id", as: "account" } },
    { $project: { equal: { $eq: [{ $first: "$account.balance" }, "$fromLegs"] } } },
    { $group: { _id: null, accounts: { $sum: 1 }, matching: { $sum: { $cond: ["$equal", 1, 0] } } } },
  ], { allowDiskUse: true }).toArray()[0];
  print(`Stored balance vs sum of posted legs: ${result.matching} of ${result.accounts} accounts with ledger activity match ` +
        `(${result.accounts - result.matching} MISMATCH), in ${Date.now() - t0} ms`);
  quit();
}

const lines = [];
lines.push(`count customers=${db.customers.countDocuments()}`);
lines.push(`count accounts=${db.accounts.countDocuments()}`);
lines.push(`count audit_events=${db.audit_events.countDocuments()}`);
db.transactions.aggregate([
  { $group: { _id: { status: "$status", type: "$type" }, count: { $sum: 1 }, amount: { $sum: "$amount" },
              legs: { $sum: { $size: "$entries" } } } },
]).forEach((g) => lines.push(`transactions ${g._id.status} ${g._id.type} count=${g.count} amount=${g.amount} legs=${g.legs}`));
db.accounts.aggregate([
  { $group: { _id: { kind: "$kind", currency: "$currency" }, accounts: { $sum: 1 }, total: { $sum: "$balance" },
              min: { $min: "$balance" }, max: { $max: "$balance" } } },
]).forEach((g) => lines.push(`balances ${g._id.kind} ${g._id.currency} accounts=${g.accounts} total=${g.total} min=${g.min} max=${g.max}`));
print(lines.join("\n"));
