// ClearPay MongoDB model: collections, validation rules and indexes.
// Usage: mongosh --quiet "mongodb://127.0.0.1:27117/clearpay?replicaSet=clearpay-rs" 02_setup.js
// DROPS the clearpay database first. Validators are created BEFORE the import, so every
// imported document is checked against them.

db = db.getSiblingDB("clearpay");
db.dropDatabase();

const uuid = { bsonType: "binData" };
const money = { bsonType: "decimal", minimum: 0, exclusiveMinimum: true };
const date = { bsonType: "date" };

// Sum of the embedded entry amounts of one type, as an aggregation expression.
const legSum = (type) => ({
  $sum: {
    $map: {
      input: { $filter: { input: "$entries", cond: { $eq: ["$$this.type", type] } } },
      in: "$$this.amount",
    },
  },
});
const has = (field) => ({ $ne: [{ $type: field }, "missing"] });

// customers ------------------------------------------------------------------------
db.createCollection("customers", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "firstName", "lastName", "email", "phone", "createdAt", "accounts"],
      additionalProperties: false,
      properties: {
        _id: uuid,
        firstName: { bsonType: "string", minLength: 1, maxLength: 100 },
        lastName: { bsonType: "string", minLength: 1, maxLength: 100 },
        email: { bsonType: "string", pattern: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", maxLength: 255 },
        phone: { bsonType: "string", pattern: "^\\+[0-9]{7,19}$" },
        createdAt: date,
        // Subset pattern: a summary of each account, for the profile screen.
        accounts: {
          bsonType: "array",
          maxItems: 10,
          items: {
            bsonType: "object",
            required: ["accountId", "accountNumber", "currency", "status"],
            additionalProperties: false,
            properties: {
              accountId: uuid,
              accountNumber: { bsonType: "string" },
              currency: { enum: ["NGN", "USD"] },
              status: { enum: ["ACTIVE", "FROZEN", "CLOSED"] },
            },
          },
        },
      },
    },
  },
  validationAction: "error",
});
db.customers.createIndex({ email: 1 }, { unique: true });
db.customers.createIndex({ phone: 1 }, { unique: true });
db.customers.createIndex({ "accounts.accountNumber": 1 }, { unique: true });

// accounts -------------------------------------------------------------------------
db.createCollection("accounts", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "accountNumber", "kind", "currency", "status", "balance", "createdAt", "updatedAt"],
      additionalProperties: false,
      properties: {
        _id: uuid,
        accountNumber: { bsonType: "string", maxLength: 20 },
        kind: { enum: ["CUSTOMER", "INTERNAL"] },
        currency: { enum: ["NGN", "USD"] },
        status: { enum: ["ACTIVE", "FROZEN", "CLOSED"] },
        customer: {
          bsonType: "object",
          required: ["customerId", "name"],
          additionalProperties: false,
          properties: { customerId: uuid, name: { bsonType: "string" } },
        },
        balance: { bsonType: "decimal" },
        createdAt: date,
        updatedAt: date,
      },
    },
    // Customer accounts have an owner and can never be overdrawn; internal settlement
    // accounts have no owner and may go negative.
    $expr: {
      $or: [
        { $and: [{ $eq: ["$kind", "CUSTOMER"] }, has("$customer"), { $gte: ["$balance", NumberDecimal("0")] }] },
        { $and: [{ $eq: ["$kind", "INTERNAL"] }, { $not: [has("$customer")] }] },
      ],
    },
  },
  validationAction: "error",
});
db.accounts.createIndex({ accountNumber: 1 }, { unique: true });
db.accounts.createIndex({ "customer.customerId": 1 });

// transactions: ledger legs embedded in the transaction they belong to ------------------
db.createCollection("transactions", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "reference", "idempotencyKey", "type", "amount", "currency", "status", "createdAt", "entries"],
      additionalProperties: false,
      properties: {
        _id: uuid,
        reference: { bsonType: "string", maxLength: 50 },
        idempotencyKey: { bsonType: "string", maxLength: 100 },
        type: { enum: ["DEPOSIT", "WITHDRAWAL", "TRANSFER", "REVERSAL"] },
        amount: money,
        currency: { enum: ["NGN", "USD"] },
        status: { enum: ["PENDING", "POSTED", "FAILED"] },
        reversalOf: uuid,
        createdAt: date,
        postedAt: date,
        postedBy: { bsonType: "string", maxLength: 100 }, // actor; set by the MongoDB application
        entries: {
          bsonType: "array",
          maxItems: 10,
          items: {
            bsonType: "object",
            required: ["line", "accountId", "accountNumber", "type", "amount"],
            additionalProperties: false,
            properties: {
              line: { bsonType: "int", minimum: 1 },
              accountId: uuid,
              accountNumber: { bsonType: "string" },
              type: { enum: ["DEBIT", "CREDIT"] },
              amount: money,
            },
          },
        },
      },
    },
    // Rules that compare fields. In PostgreSQL the balanced-entry rule needed a deferred
    // trigger across two tables; here the legs are inside the document, so one
    // expression checks them on every insert and update.
    $expr: {
      $and: [
        { $eq: [{ $eq: ["$type", "REVERSAL"] }, has("$reversalOf")] }, // reversal link only on reversals
        { $eq: [{ $eq: ["$status", "POSTED"] }, has("$postedAt")] }, // postedAt only when posted
        {
          $or: [
            { $ne: ["$status", "POSTED"] },
            {
              $and: [
                { $gte: [{ $size: "$entries" }, 2] },
                { $eq: [legSum("DEBIT"), "$amount"] },
                { $eq: [legSum("CREDIT"), "$amount"] },
              ],
            },
          ],
        },
      ],
    },
  },
  validationAction: "error",
});
db.transactions.createIndex({ reference: 1 }, { unique: true });
db.transactions.createIndex({ idempotencyKey: 1 }, { unique: true });
// MongoDB indexes a missing field as null, so a plain unique index would allow only one
// non-reversal. The partial index covers reversals only (PostgreSQL got this for free,
// because NULLs are distinct in a unique constraint).
db.transactions.createIndex(
  { reversalOf: 1 },
  { unique: true, partialFilterExpression: { reversalOf: { $exists: true } } }
);
// The account-statement index is created in 04_queries.js, after the "before" measurement.

// audit_events: time-series collection --------------------------------------------------
db.createCollection("audit_events", {
  timeseries: { timeField: "at", metaField: "meta", granularity: "hours" },
});
db.audit_events.createIndex({ "meta.actor": 1, at: -1 });

// daily_limits: key-value counters that expire ------------------------------------------
// Key "<account number>|<YYYY-MM-DD>"; value = amount withdrawn that day. The TTL index
// deletes each counter after its expiresAt time, like a cache entry with an expiry.
db.createCollection("daily_limits", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "total", "count", "expiresAt"],
      properties: {
        _id: { bsonType: "string", pattern: "^[^|]+\\|[0-9]{4}-[0-9]{2}-[0-9]{2}$" },
        total: { bsonType: "decimal" },
        count: { bsonType: ["int", "long"] },
        expiresAt: date,
      },
    },
  },
});
db.daily_limits.createIndex({ expiresAt: 1 }, { expireAfterSeconds: 0 });

print("Collections and indexes:");
for (const name of db.getCollectionNames().filter((n) => !n.startsWith("system.")).sort()) {
  const info = db.getCollectionInfos({ name })[0];
  const kind = info.options.timeseries ? "time-series" : info.options.validator ? "validated" : "plain";
  const idx = db.getCollection(name).getIndexes().map((i) =>
    JSON.stringify(i.key) + (i.unique ? " unique" : "") +
    (i.partialFilterExpression ? " partial" : "") +
    (i.expireAfterSeconds !== undefined ? ` TTL(${i.expireAfterSeconds}s)` : ""));
  print(`  ${name.padEnd(14)} ${kind.padEnd(12)} ${idx.join(", ")}`);
}
