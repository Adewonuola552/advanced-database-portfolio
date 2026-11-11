// ClearPay operations on the MongoDB model, with multi-document ACID transactions.
// Usage: mongosh --quiet "mongodb://127.0.0.1:27117/clearpay?replicaSet=clearpay-rs" 03_operations.js
// Run after the import (run_all.sh does this). It adds demo customers, so re-run the
// whole pipeline rather than this script on its own.

db = db.getSiblingDB("clearpay");
const client = db.getMongo();
const D = (x) => NumberDecimal(String(x));
const DAILY_WITHDRAWAL_LIMIT = 10000; // NGN, kept low so the demo can reach it
const TXN_OPTIONS = { readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } };

function heading(text) { print("\n=== " + text); }
function balances(...numbers) {
  db.accounts.find({ accountNumber: { $in: numbers } }, { _id: 0, accountNumber: 1, status: 1, balance: 1 })
    .sort({ accountNumber: 1 })
    .forEach((a) => print(`    ${a.accountNumber}  ${a.status.padEnd(6)}  balance ${a.balance}`));
}
function errorText(e) {
  const labels = e.errorLabels ? [...e.errorLabels] : [];
  return (e.code ? `${e.codeName || "error"} (code ${e.code})` : "rejected") + ": " + e.message.split("\n")[0] +
    failedRules(e.errInfo) +
    (labels.length ? `  [labels: ${labels.join(", ")}]` : "");
}

// Which validator clause rejected a document: $jsonSchema (and on which fields) or $expr.
function failedRules(info) {
  if (!info || !info.details) return "";
  const clauses = info.details.clausesNotSatisfied ? info.details.clausesNotSatisfied.map((c) => c.details) : [info.details];
  return "  [failed: " + clauses.map((d) => {
    const fields = [...new Set([...JSON.stringify(d).matchAll(/"propertyName":"([^"]+)"/g)].map((m) => m[1]))];
    return d.operatorName + (fields.length ? ` on ${fields.join(", ")}` : "");
  }).join("; ") + "]";
}
function show(v) {
  if (v && v.sub_type === 4) return v.toString("hex").replace(/(.{8})(.{4})(.{4})(.{4})(.{12})/, "$1-$2-$3-$4-$5");
  return v;
}

// Runs fn(sessionDb) in a transaction. Retries the whole transaction on
// TransientTransactionError (for example a write conflict), as the MongoDB drivers do.
function inTransaction(fn, attempts = 3) {
  for (let attempt = 1; ; attempt++) {
    const session = client.startSession();
    try {
      session.startTransaction(TXN_OPTIONS);
      const result = fn(session.getDatabase("clearpay"));
      session.commitTransaction();
      return result;
    } catch (e) {
      try { session.abortTransaction(); } catch (_) {} // already aborted by the server
      const transient = e.errorLabels && [...e.errorLabels].includes("TransientTransactionError");
      if (transient && attempt < attempts) {
        print(`    attempt ${attempt} hit ${e.codeName}; retrying the whole transaction`);
        continue;
      }
      throw e;
    } finally {
      session.endSession();
    }
  }
}

// Posting: the same rules as the PostgreSQL procedure in Portfolio 3.
// postIn runs inside a transaction that the caller controls; post() wraps it in one.
// Time-series collections cannot be written inside a multi-document transaction, so the
// actor is stored in the transaction document (committed atomically with the money
// movement) and the audit_events entry is written after the commit.
function post(request) {
  const id = inTransaction((s) => postIn(s, request));
  if (id && !request.replayed) audit(request, id);
  return id;
}
function audit({ type, reference, debit, credit, amount, actor }, id) {
  db.audit_events.insertOne({ at: new Date(), meta: { actor, action: type + "_POSTED" }, transactionId: id,
                              details: { reference, debit, credit, amount: D(amount) } });
}
function postIn(s, request) {
  const { type, idempotencyKey, reference, debit, credit, amount, actor, reversalOf } = request;
  {
    // 1. Idempotency: the unique index on idempotencyKey is the final guard.
    const existing = s.transactions.findOne({ idempotencyKey });
    if (existing) {
      const same = existing.type === type && existing.amount.toString() === D(amount).toString() &&
        existing.entries[0].accountNumber === debit && existing.entries[1].accountNumber === credit;
      if (!same) throw new Error(`idempotency key ${idempotencyKey} was already used for a different request (${existing.reference})`);
      print(`    idempotency key ${idempotencyKey} already processed as ${existing.reference}: returning it`);
      request.replayed = true;
      return existing._id;
    }
    const from = s.accounts.findOne({ accountNumber: debit });
    const to = s.accounts.findOne({ accountNumber: credit });
    if (!from || !to) throw new Error("unknown account");
    if (from.currency !== to.currency) throw new Error("currency mismatch");
    for (const a of [from, to]) {
      if (a.kind === "CUSTOMER" && a.status !== "ACTIVE") throw new Error(`account ${a.accountNumber} is ${a.status}`);
    }

    // 2. Daily withdrawal limit, a key-value counter (upsert + $inc is atomic).
    if (type === "WITHDRAWAL") {
      const day = new Date().toISOString().slice(0, 10);
      const counter = s.daily_limits.findOneAndUpdate(
        { _id: `${debit}|${day}` },
        { $inc: { total: D(amount), count: 1 }, $setOnInsert: { expiresAt: new Date(Date.parse(day) + 2 * 86400000) } },
        { upsert: true, returnDocument: "after" });
      if (Number(counter.total.toString()) > DAILY_WITHDRAWAL_LIMIT)
        throw new Error(`daily withdrawal limit ${DAILY_WITHDRAWAL_LIMIT} exceeded for ${debit} (would be ${counter.total})`);
    }

    // 3. Conditional debit: the filter only matches if the funds are there, so the check
    //    and the write are one atomic operation on the document.
    const debitFilter = { _id: from._id, ...(from.kind === "CUSTOMER" ? { balance: { $gte: D(amount) } } : {}) };
    const now = new Date();
    const res = s.accounts.updateOne(debitFilter, { $inc: { balance: D(-amount) }, $set: { updatedAt: now } });
    if (res.matchedCount !== 1) throw new Error(`insufficient funds in ${debit}: balance ${from.balance}, requested ${amount}`);
    s.accounts.updateOne({ _id: to._id }, { $inc: { balance: D(amount) }, $set: { updatedAt: now } });

    // 4. The transaction document, with its two legs embedded.
    const id = UUID();
    s.transactions.insertOne({
      _id: id, reference, idempotencyKey, type, amount: D(amount), currency: from.currency,
      status: "POSTED", ...(reversalOf ? { reversalOf } : {}), createdAt: now, postedAt: now, postedBy: actor,
      entries: [
        { line: 1, accountId: from._id, accountNumber: debit, type: "DEBIT", amount: D(amount) },
        { line: 2, accountId: to._id, accountNumber: credit, type: "CREDIT", amount: D(amount) },
      ],
    });
    return id;
  }
}

function attempt(label, fn) {
  try { const r = fn(); print(`    ${label}: OK ${r ? "-> " + show(r) : ""}`); return r; }
  catch (e) { print(`    ${label}: ${errorText(e)}`); }
}

// Customer registration writes two collections, so it is one transaction.
function registerCustomer(first, last, email, phone, accountNumber) {
  return inTransaction((s) => {
    const customerId = UUID(), accountId = UUID(), now = new Date();
    s.accounts.insertOne({ _id: accountId, accountNumber, kind: "CUSTOMER", currency: "NGN", status: "ACTIVE",
                           customer: { customerId, name: `${first} ${last}` }, balance: D(0), createdAt: now, updatedAt: now });
    s.customers.insertOne({ _id: customerId, firstName: first, lastName: last, email, phone, createdAt: now,
                            accounts: [{ accountId, accountNumber, currency: "NGN", status: "ACTIVE" }] });
    return accountNumber;
  });
}

// Status is stored in accounts and copied into customers.accounts, so both change together.
function setAccountStatus(accountNumber, status) {
  return inTransaction((s) => {
    s.accounts.updateOne({ accountNumber }, { $set: { status, updatedAt: new Date() } });
    s.customers.updateOne({ "accounts.accountNumber": accountNumber }, { $set: { "accounts.$.status": status } });
  });
}

// --------------------------------------------------------------------------------------
heading("Setup: register three demo customers (customer + account written in one transaction)");
registerCustomer("Amina", "Bello", "amina.bello@example.com", "+2348100000001", "0012345601");
registerCustomer("Tunde", "Okoro", "tunde.okoro@example.com", "+2348100000002", "0012345602");
registerCustomer("Musa", "Ibrahim", "musa.ibrahim@example.com", "+2348100000005", "0012345605");
attempt("deposit 20,000 to Amina", () => post({ type: "DEPOSIT", idempotencyKey: "p4-dep-1", reference: "P4-DEP-1",
  debit: "INT-NGN-01", credit: "0012345601", amount: 20000, actor: "teller.01" }));
setAccountStatus("0012345605", "FROZEN");
balances("0012345601", "0012345602", "0012345605");
print("    Musa's profile, one read with no join (status copied into the customer document):");
printjson(db.customers.findOne({ email: "musa.ibrahim@example.com" }, { _id: 0, firstName: 1, accounts: 1 }));

heading("1. COMMIT: Amina transfers 5,000 to Tunde");
const trf = attempt("transfer", () => post({ type: "TRANSFER", idempotencyKey: "p4-req-1001", reference: "P4-TRF-1001",
  debit: "0012345601", credit: "0012345602", amount: 5000, actor: "amina.mobile-app" }));
balances("0012345601", "0012345602");
print("    The transaction document, with its ledger legs embedded:");
printjson(db.transactions.findOne({ _id: trf }));

heading("2. ROLLBACK: insufficient funds aborts the transaction; nothing is written");
attempt("transfer 50,000", () => post({ type: "TRANSFER", idempotencyKey: "p4-req-1002", reference: "P4-TRF-1002",
  debit: "0012345601", credit: "0012345602", amount: 50000, actor: "amina.mobile-app" }));
balances("0012345601", "0012345602");
print(`    documents with reference P4-TRF-1002: ${db.transactions.countDocuments({ reference: "P4-TRF-1002" })}`);

heading("3. Eligibility: a frozen account cannot receive a transfer");
attempt("transfer to Musa", () => post({ type: "TRANSFER", idempotencyKey: "p4-req-1003", reference: "P4-TRF-1003",
  debit: "0012345601", credit: "0012345605", amount: 1000, actor: "amina.mobile-app" }));

heading("4. Idempotency: a retry returns the original; a reused key with new details is rejected");
attempt("retry of p4-req-1001", () => post({ type: "TRANSFER", idempotencyKey: "p4-req-1001", reference: "P4-TRF-1001-RETRY",
  debit: "0012345601", credit: "0012345602", amount: 5000, actor: "amina.mobile-app" }));
attempt("p4-req-1001 with 9,999", () => post({ type: "TRANSFER", idempotencyKey: "p4-req-1001", reference: "P4-TRF-1004",
  debit: "0012345601", credit: "0012345602", amount: 9999, actor: "amina.mobile-app" }));
print(`    transactions with key p4-req-1001: ${db.transactions.countDocuments({ idempotencyKey: "p4-req-1001" })}`);

heading("5. Validation: the database rejects bad documents even if application code is bypassed");
attempt("insert an unbalanced POSTED transaction (debit 5,000, credit 4,000)", () => db.transactions.insertOne({
  _id: UUID(), reference: "P4-BAD-1", idempotencyKey: "p4-bad-1", type: "TRANSFER", amount: D(5000), currency: "NGN",
  status: "POSTED", createdAt: new Date(), postedAt: new Date(),
  entries: [{ line: 1, accountId: UUID(), accountNumber: "0012345601", type: "DEBIT", amount: D(5000) },
            { line: 2, accountId: UUID(), accountNumber: "0012345602", type: "CREDIT", amount: D(4000) }] }).insertedId);
attempt("set a customer balance below zero directly", () => db.accounts.updateOne(
  { accountNumber: "0012345602" }, { $set: { balance: D(-1) } }).modifiedCount);
attempt("insert a transaction with a negative amount", () => db.transactions.insertOne({
  _id: UUID(), reference: "P4-BAD-2", idempotencyKey: "p4-bad-2", type: "DEPOSIT", amount: D(-10), currency: "NGN",
  status: "PENDING", createdAt: new Date(), entries: [] }).insertedId);

heading(`6. Key-value counter: daily withdrawal limit of ${DAILY_WITHDRAWAL_LIMIT}`);
attempt("withdraw 6,000", () => post({ type: "WITHDRAWAL", idempotencyKey: "p4-wdr-1", reference: "P4-WDR-1",
  debit: "0012345601", credit: "INT-NGN-01", amount: 6000, actor: "atm-1" }));
attempt("withdraw another 6,000", () => post({ type: "WITHDRAWAL", idempotencyKey: "p4-wdr-2", reference: "P4-WDR-2",
  debit: "0012345601", credit: "INT-NGN-01", amount: 6000, actor: "atm-1" }));
print("    The counter (the rejected withdrawal's increment was rolled back with its transaction):");
db.daily_limits.find({ _id: /^0012345601\|/ }).forEach((d) => print(`    ${d._id}  total ${d.total}  count ${d.count}  expiresAt ${d.expiresAt.toISOString()}`));
balances("0012345601");

heading("7. Concurrency: two transfers from Amina (balance 9,000) of 8,000 each, at the same time");
print("    Session A and session B each start a transaction and run the posting steps.");
const sa = client.startSession(), sb = client.startSession();
sa.startTransaction(TXN_OPTIONS); sb.startTransaction(TXN_OPTIONS);
const reqA = { type: "TRANSFER", idempotencyKey: "p4-req-A", reference: "P4-TRF-A", debit: "0012345601",
               credit: "0012345602", amount: 8000, actor: "amina.mobile-app" };
const reqB = { ...reqA, idempotencyKey: "p4-req-B", reference: "P4-TRF-B", actor: "amina.web" };
print(`    A: posted ${show(postIn(sa.getDatabase("clearpay"), reqA))} (not yet committed)`);
try {
  postIn(sb.getDatabase("clearpay"), reqB);
  print("    B: posted (unexpected)");
} catch (e) { print("    B: " + errorText(e)); }
try { sb.abortTransaction(); } catch (_) {}
sa.commitTransaction(); audit(reqA, db.transactions.findOne({ reference: "P4-TRF-A" })._id); print("    A: committed");
sa.endSession(); sb.endSession();
print("    B's client sees TransientTransactionError and retries the whole transaction:");
attempt("B retry", () => post(reqB));
balances("0012345601", "0012345602");

heading("8. Reversal: a new REVERSAL document; a second reversal is blocked by the partial unique index");
attempt("reverse P4-TRF-1001", () => post({ type: "REVERSAL", idempotencyKey: "p4-rev-1001", reference: "P4-REV-1001",
  debit: "0012345602", credit: "0012345601", amount: 5000, actor: "finance.officer1", reversalOf: trf }));
attempt("reverse it again with a new key", () => post({ type: "REVERSAL", idempotencyKey: "p4-rev-1001-b", reference: "P4-REV-1001-B",
  debit: "0012345601", credit: "0012345602", amount: 1, actor: "finance.officer2", reversalOf: trf }));
balances("0012345601", "0012345602");

heading("Final check: every demo account's stored balance equals the sum of its posted legs");
db.transactions.aggregate([
  { $match: { status: "POSTED", "entries.accountNumber": { $in: ["0012345601", "0012345602", "0012345605"] } } },
  { $unwind: "$entries" },
  { $match: { "entries.accountNumber": { $in: ["0012345601", "0012345602", "0012345605"] } } },
  { $group: { _id: "$entries.accountNumber",
              fromLegs: { $sum: { $cond: [{ $eq: ["$entries.type", "CREDIT"] }, "$entries.amount", { $multiply: ["$entries.amount", -1] }] } } } },
  { $lookup: { from: "accounts", localField: "_id", foreignField: "accountNumber", as: "a" } },
  { $project: { stored: { $first: "$a.balance" }, fromLegs: 1, equal: { $eq: [{ $first: "$a.balance" }, "$fromLegs"] } } },
  { $sort: { _id: 1 } },
]).forEach((r) => print(`    ${r._id}  stored ${r.stored}  from legs ${r.fromLegs}  ${r.equal ? "MATCH" : "MISMATCH"}`));
