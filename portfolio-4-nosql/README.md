# Portfolio 4: NoSQL and Advanced Data Models

MIT 8103 Advanced Database Systems, 2026/2027 Academic Session, First Semester Continuous Assessment

Case study: **ClearPay Digital Fintech Platform** (see the [root README](../README.md)). This portfolio models ClearPay in **MongoDB 7.0.2**. It migrates the full Portfolio 2 dataset (20,000 customers, 30,002 accounts, 534,841 transactions, 100,000 audit records) from PostgreSQL, and reconciles the copy against the source.

| File | Contents |
| --- | --- |
| [start_mongo.sh](start_mongo.sh) | Starts a local single-node replica set on port 27117 (multi-document transactions need a replica set) |
| [01_export_from_postgres.sql](01_export_from_postgres.sql) | Turns the relational rows into MongoDB documents (Extended JSON, one per line) |
| [02_setup.js](02_setup.js) | Collections, validators (`$jsonSchema` + `$expr`) and indexes |
| [03_operations.js](03_operations.js) | Postings as multi-document ACID transactions; idempotency, limits, validation, concurrency, reversal |
| [04_queries.js](04_queries.js) | Read patterns with `explain()`: profile, statement (before and after an index), analytics, graph, time-series |
| [05_reconcile_postgres.sql](05_reconcile_postgres.sql), [05_reconcile_mongo.js](05_reconcile_mongo.js) | The same summary from both databases, compared with `diff` |
| [run_all.sh](run_all.sh) | Runs everything in order and writes [evidence/](evidence/) |

## 1. Which NoSQL Models, and for What

ClearPay keeps PostgreSQL as its system of record for money (Portfolios 1 to 3). MongoDB is evaluated here for the same data, using four NoSQL models where each one fits a real ClearPay need:

| Model | ClearPay use | MongoDB feature | Why it suits this data |
| --- | --- | --- | --- |
| **Document** | Transactions with their ledger legs; customer profiles | Embedded arrays, `$jsonSchema` validation | A transaction and its legs are created together, read together and never change. Embedding stores them as one unit. |
| **Key-value** | Daily withdrawal limit per account | `_id` = `"<account>\|<date>"`, atomic `$inc`, TTL index | A counter looked up only by its key, which should disappear after two days: a cache-style key-value workload |
| **Graph** | Compliance: trace where money from a flagged account went | `$graphLookup` over account-to-account edges | Following transfers hop by hop is a graph traversal. In SQL it needs a recursive CTE. |
| **Time-series** | Audit events (logins, complaints, reversal approvals) | Time-series collection, `metaField` = actor + action | Append-only, timestamped, queried by time range; bucketed storage compresses it |

## 2. Document Model

```text
customers                               accounts
{ _id: UUID,                            { _id: UUID, accountNumber: "0000020001",
  firstName, lastName, email, phone,      kind: "CUSTOMER" | "INTERNAL", currency, status,
  createdAt,                              customer: { customerId, name },   <- extended reference
  accounts: [                             balance: Decimal128,              <- stored balance
    { accountId, accountNumber,           createdAt, updatedAt }
      currency, status } ] }            <- subset pattern

transactions                            audit_events (time-series)       daily_limits (key-value)
{ _id: UUID, reference, idempotencyKey,  { at: Date,                       { _id: "0012345601|2026-11-11",
  type, amount: Decimal128, currency,      meta: { actor, action },          total: Decimal128, count,
  status, reversalOf?, createdAt,          transactionId?, details }         expiresAt }   <- TTL
  postedAt?, postedBy?,
  entries: [ { line, accountId, accountNumber, type: "DEBIT"|"CREDIT", amount } ] }
```

### Design decisions

| Decision | Reason | Trade-off |
| --- | --- | --- |
| **Embed** ledger legs in the transaction | Written once and always read with the transaction. Portfolio 1's balanced-entry rule needed a deferred trigger across two tables; here it is one `$expr` on one document. | A statement query must search inside arrays, which needs a multikey index (Q2). |
| **Reference** accounts from customers, and keep a **subset** (number, currency, status) in the customer | The profile screen is one read. The full account document changes on every posting, so it is not embedded. | Status is stored twice. Changing it updates both documents in one transaction (`setAccountStatus`). |
| **Store** the balance on the account | A posting can check funds and debit in one atomic conditional update (`balance: {$gte: amount}`). The relational design derives balances from the ledger instead. | The stored balance could drift from the ledger. The reconciliation checks every account against its legs (section 5). |
| **Extended reference**: copy the owner's name into the account | A statement header needs no `$lookup` | The name must be updated in two places if it changes |
| **Decimal128** for money, **BSON UUID** for keys | Exact decimal arithmetic, as `NUMERIC(18,2)` in PostgreSQL; 16-byte binary IDs | `$jsonSchema` cannot fix the scale at two decimal places |

### Validation inside the database

[02_setup.js](02_setup.js) creates the validators **before** the import, so all 684,843 imported documents were checked: 0 failed ([03-import.txt](evidence/03-import.txt)). The transaction validator combines:

- `$jsonSchema`: required fields, enums for type, status and currency, amount > 0, entry structure, and no unknown fields (`additionalProperties: false`).
- `$expr`: `reversalOf` only on reversals, `postedAt` only when POSTED, and for POSTED transactions at least two legs with **debits = credits = amount**.

The account validator uses `$expr` to require customer balances ≥ 0 and an owner on every customer account. Uniqueness uses indexes. `reversalOf` needs a **partial** unique index: MongoDB indexes a missing field as null, so a plain unique index would allow only one non-reversal. PostgreSQL avoided this because NULLs are distinct in a unique constraint.

## 3. Migration from PostgreSQL

| Step | Result | Evidence |
| --- | --- | --- |
| Export 684,843 documents with `json_build_object` (UUID, Decimal128 and dates as Extended JSON) | 23.3 s | [01-export.txt](evidence/01-export.txt) |
| `mongoimport`, 4 workers, validators active | 0 documents failed; transactions (339 MB of JSON) in about 9 s | [03-import.txt](evidence/03-import.txt) |
| Compare the summaries from both databases with `diff` | **IDENTICAL**: counts, amounts and leg counts per status and type, and balance totals, minimums and maximums per account kind and currency | [05-reconcile.txt](evidence/05-reconcile.txt) |
| Recompute each stored balance from the embedded legs | **30,002 of 30,002 accounts match** (2.5 s) | same |

Storage after import (WiredTiger, snappy compression) compared with Portfolio 2's PostgreSQL tables:

| Data | PostgreSQL (Portfolio 2, table data) | MongoDB (storage size) |
| --- | --- | --- |
| Transactions + ledger entries | 65 MB + 126 MB in two tables | 67 MB in one collection |
| Audit events | 13 MB | 2.8 MB (time-series) |

Embedding removes the second copy of the transaction ID and the per-row overhead of a million ledger rows. MongoDB also compresses on disk while PostgreSQL does not, so this is not a like-for-like measure of the data model alone.

## 4. Operations and Transactions

All postings run in a multi-document transaction (`readConcern: snapshot`, `writeConcern: majority`). Each one checks idempotency, eligibility and the daily limit, debits with a conditional update, credits, and inserts the transaction document. These are the same rules as the Portfolio 3 PostgreSQL procedure. Output: [03-operations.txt](evidence/03-operations.txt).

| # | Operation | Result |
| --- | --- | --- |
| Setup | Register customers (customer + account in one transaction); deposit 20,000; freeze Musa's account | Musa's profile shows `status: 'FROZEN'` in the embedded summary, from one read with no join |
| 1 | COMMIT: Amina transfers 5,000 to Tunde | Balances 15,000 / 5,000; one transaction document with both legs embedded |
| 2 | Transfer 50,000 (insufficient funds) | Aborted; balances unchanged; 0 documents with that reference |
| 3 | Transfer to a frozen account | `account 0012345605 is FROZEN` |
| 4 | Retry with the same idempotency key, then the same key with 9,999 | The retry returned the **same `_id`**; the changed request was rejected; one document has the key |
| 5 | Bypass the application: insert an unbalanced POSTED transaction; set a balance to -1; insert a negative amount | All rejected with code 121. The tool names the failing clause: `$expr` for the first two, `$jsonSchema on amount` for the third |
| 6 | Key-value limit (10,000 a day): withdraw 6,000, then 6,000 again | The second was rejected (`would be 12000`). Its counter increment was **rolled back with the transaction**: the counter reads total 6,000, count 1, expiring two days later |
| 7 | **Concurrency**: sessions A and B each transfer 8,000 from Amina's 9,000 at the same time | A's uncommitted write is in place. B's debit failed **immediately** with `WriteConflict (code 112)` and the label `TransientTransactionError`. A committed. B's retry read 1,000 and was rejected |
| 8 | Reverse transfer 1, then reverse it again with a new key | The first posted a REVERSAL document. The second hit `E11000 duplicate key ... reversalOf_1`, from the partial unique index |
| Final | Stored balance vs sum of legs for the demo accounts | MATCH |

**Concurrency compared with PostgreSQL.** In Portfolio 3 (S07), the second withdrawal **waited** on a row lock and then saw the new balance. MongoDB uses optimistic, first-writer-wins control instead. A second transaction that writes a document already modified by an uncommitted transaction fails at once with a write conflict. The client must retry, as `inTransaction()` does for `TransientTransactionError`. Both prevent the double spend; they differ in who waits and who retries.

**Design change found during testing.** The first version wrote the audit event inside the posting transaction. MongoDB refused: `Cannot insert into a time-series collection in a multi-document transaction`. The actor is now stored in the transaction document (`postedBy`), which is committed atomically with the money movement. The time-series audit event is written after the commit. If the process crashed in between, the audit stream could miss an event, but the financial record would still name the actor.

## 5. Queries and Execution Plans

Output: [04-queries.txt](evidence/04-queries.txt). Times are medians of 5 runs after a warm-up, on a local single node.

| Query | Plan | Work | Time |
| --- | --- | --- | --- |
| Q1 Customer profile with accounts (by email) | `FETCH <- IXSCAN(email_1)` | 1 key, 1 document | < 1 ms |
| Q2 Statement, latest 20, **before** the index | `SORT <- COLLSCAN` | 534,841 documents examined | 248 ms |
| Q2 Statement, latest 20, **after** `{entries.accountId: 1, status: 1, postedAt: -1}` | `LIMIT <- FETCH <- IXSCAN(statement_idx)`, **no SORT stage** | 20 keys, 20 documents, for both the busiest account (2,640 transactions) and a typical one (28) | 1 ms |
| Q3 Monthly volume by type, 2026 | Collection scan + `$group` | All documents | 360 ms |
| Q4 Money trail, 3 hops, links ≥ 20,000 | `$graphLookup` on the `from` index | 3, then 9, then 46 links | 3 ms |
| Q5 Audit events per month for finance officers | Time-series buckets | | 4 ms |

**Q2.** The index follows the ESR rule: equality fields first (`entries.accountId`, `status`), then the sort field (`postedAt`). The index returns documents already in order, so the plan has no SORT stage and stops after 20 keys. `entries` is an array, so this is a **multikey** index with one key per leg. It is the MongoDB equivalent of Portfolio 2's `idx_ledger_account_created`.

**Q3** scans everything. Adding an index for a monthly report would slow every posting for the sake of one report. Portfolio 5 runs such reports on a secondary instead.

**Q4 Graph.** An aggregation turns 338,432 posted transfers into 338,041 account-to-account edges (`from`, `to`, number of transfers, total). `$graphLookup` then follows edges from flagged account 0000020001, keeping only links that total at least 20,000. It found 3 accounts at hop 1, 9 at hop 2 and 46 at hop 3, with 72,550.13, 320,079.65 and 1,414,818.44 moved. `$graphLookup` handles cycles by visiting each edge once.

**Q5 Time-series storage.** The same 100,000 audit events were stored three ways:

| Storage | Buckets | Size |
| --- | --- | --- |
| Time-series, inserted in time order | 3,003 | 2,888 KB |
| Time-series, inserted in random order | 5,196 | 3,264 KB |
| Regular collection | | 5,072 KB |

The first import was in random (UUID) order and produced 44,047 buckets for 100,000 events. Out-of-order measurements cannot join a bucket that already covers a later time range, so MongoDB opens new ones. The export now sorts by time (`ORDER BY created_at`), and the random-order copy is kept in Q5 as a comparison.

## 6. Suitability: MongoDB vs PostgreSQL for ClearPay

| Requirement | MongoDB | PostgreSQL |
| --- | --- | --- |
| Balanced double entry | One document-level `$expr`, checked on every write | Deferred constraint trigger across two tables |
| Atomic multi-account posting | Multi-document transaction, which needs a replica set; conflicts are retried | Native; row locks wait |
| Rules across documents (account must exist, reversal must match the original) | Application code only; no foreign keys | Foreign keys and triggers |
| Statement and profile reads | One document or index range; no joins | Joins (fast with the Portfolio 2 indexes) |
| Changing audit detail formats | Natural | JSONB column |
| Ad-hoc reporting across entities | `$lookup` is possible but awkward | SQL |
| Horizontal scale-out | Built-in sharding (Portfolio 5) | Needs extensions or application sharding |

**Conclusion.** MongoDB can hold ClearPay's financial data correctly, as the reconciliation and the validation tests show. It does so by moving integrity rules into validators and application code that PostgreSQL enforces declaratively. A sensible split for ClearPay keeps the **ledger in PostgreSQL**. MongoDB would serve **read-heavy and flexible** data: customer and statement views built from the ledger, the audit and event stream (time-series), counters and limits (key-value), and compliance graph analysis.

## 7. How to Reproduce

Requires PostgreSQL with the Portfolio 2 data loaded (database `clearpay_p2`), and MongoDB 7 with mongosh and the database tools.

```bash
./run_all.sh            # or ./run_all.sh <postgres-database>
./start_mongo.sh stop   # stop the local replica set afterwards
```

`run_all.sh` drops and rebuilds the MongoDB `clearpay` database each time. Generated files go to `.export/` and `.mongo-data/`, which are git-ignored.

## 8. Limitations

- **Single node.** The replica set has one member, so `writeConcern: majority` is satisfied by that one node. Replication, failover and sharding are tested in Portfolio 5.
- **No cross-document integrity.** Nothing in MongoDB stops a transaction document from naming an account that does not exist. Only the posting code prevents it.
- **Audit write after commit**, as explained in section 4.
- **The daily limit is compared in JavaScript** (`Number(...)`), not as an exact decimal. The amounts here are small enough for that to be exact; production code should compare with Decimal128 on the server.
- **Time measurements** are from one laptop with a warm cache, so they show relative differences, not production figures.

## AI Use Declaration

- **Tool used:** Claude Code (Claude Opus 5.5).
- **Used for:** designing the document model with the student, and writing the export, setup, operations, query and reconciliation scripts and this README.
- **How the output was checked:** the pipeline was run end to end on MongoDB 7.0.2. The migration was reconciled against PostgreSQL with `diff`, and every account balance was recomputed from its legs. Several first attempts failed or gave misleading evidence, and were investigated and fixed rather than hidden:
  - writing a time-series collection inside a transaction;
  - `$out` to a time-series collection, which is not supported in 7.0.2;
  - a bucket count inflated by random insert order;
  - a storage figure read before the data was flushed to disk;
  - a graph threshold that returned no results.
