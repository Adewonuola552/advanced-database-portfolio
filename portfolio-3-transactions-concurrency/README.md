# Portfolio 3: Transactions and Concurrency

MIT 8103 Advanced Database Systems, 2026/2027 Academic Session, First Semester Continuous Assessment

Case study: **ClearPay Digital Fintech Platform** (see the [root README](../README.md)). This portfolio uses the Portfolio 1 schema unchanged and adds the posting procedures that Portfolio 1 left planned.

| File | Contents |
| --- | --- |
| [01_procedures.sql](01_procedures.sql) | Posting procedures: deposit, withdrawal, transfer and reversal, with locking, funds check, eligibility and idempotency |
| [02_fixture.sql](02_fixture.sql) | Starting accounts and balances for every scenario |
| [03_unsafe_demo_functions.sql](03_unsafe_demo_functions.sql) | Deliberately unsafe code, used only to reproduce the concurrency problems |
| [scenarios/](scenarios/) | One SQL file per database session for each scenario, plus `check.sql` |
| [run_scenarios.py](run_scenarios.py) | Rebuilds the database, runs the sessions concurrently, timestamps the output and checks the outcome |
| [evidence/](evidence/) | One timeline per scenario, [summary.txt](evidence/summary.txt) and [server-settings.txt](evidence/server-settings.txt) |

## 1. Why ClearPay Needs Transaction Control

Two ClearPay design decisions from Portfolio 1 make this portfolio necessary:

1. **Balances are derived from the ledger.** There is no balance column to update, so a posting *inserts* rows. Two postings on the same account never touch the same row, and PostgreSQL has no row conflict to detect. Without explicit control, two withdrawals can both read the same balance and both succeed (scenario S06).
2. **Every posting writes several rows:** a transaction row, two ledger entries, a status update and an audit record. They must all be written or none of them (atomicity), and the balanced-entry trigger can only judge them together at COMMIT.

## 2. The Posting Procedure

All postings go through `post_two_leg` in [01_procedures.sql](01_procedures.sql). `post_deposit`, `post_withdrawal`, `post_transfer` and `reverse_transaction` choose the accounts and call it. Each call runs these steps inside the caller's transaction:

| Step | What it does | Rule from Portfolio 1 it implements |
| --- | --- | --- |
| 1. Lock | `SELECT ... FOR UPDATE` on both account rows, **in `account_id` order** | Concurrency control; deadlock avoidance |
| 2. Idempotency | The same key with the same details returns the original transaction; the same key with different details is rejected | "Rejecting a reused idempotency key with different request details" |
| 3. Eligibility | Customer accounts must be ACTIVE; both accounts must share a currency | "Account eligibility" |
| 4. Funds | Balance read **after** the lock is held; reject if below the amount | "Sufficient available funds" |
| 5. Write | Transaction (PENDING), two ledger legs, POSTED, audit record | Balanced entries checked by the Portfolio 1 deferred trigger at COMMIT |

The account row acts as a mutex for that account's ledger. Any posting that debits or credits an account must first hold that account's row lock. Under READ COMMITTED, each statement takes a new snapshot, so the balance read in step 4 includes everything committed while the session waited for the lock.

**Isolation guard.** The procedure refuses to run under REPEATABLE READ. That level fixes the snapshot at the transaction's first statement, so a session that waited for the lock would still read the old balance. Scenario S09 proves this by switching the guard off with the demo-only setting `clearpay.unsafe_allow_repeatable_read`.

## 3. How the Scenarios Were Run

Tested on PostgreSQL 15.13, default isolation READ COMMITTED, `deadlock_timeout` = 1s ([server-settings.txt](evidence/server-settings.txt)). To reproduce, from this folder:

```bash
python3 run_scenarios.py              # all scenarios; uses (and drops) database clearpay_p3
python3 run_scenarios.py clearpay_p3 S07_row_locks   # one scenario
```

For each scenario the runner:

1. Rebuilds `clearpay_p3` from the Portfolio 1 schema, the procedures and the fixture.
2. Starts each session file as a **separate psql connection** at a fixed offset (for example, A at 0.0s and B at 0.5s).
3. Timestamps every output line as it arrives. psql echoes each statement *before* running it, so a statement that blocks shows up in the timeline before the gap.
4. Prints the final state from a new connection, and runs a query that confirms the expected outcome (PASS/FAIL).

The concurrency scenarios use `pg_sleep` to hold a transaction open. This stands in for application work between the read and the write, such as a fraud check or a call to a partner bank. It makes the race happen on every run instead of occasionally.

Starting balances ([02_fixture.sql](02_fixture.sql)): Amina 0012345601 = 20,000; Tunde 0012345602 = 5,000; Chiamaka 0012345603 = 0; Kemi 0012345604 = 100,000 (business account); Musa 0012345605 = 0 and FROZEN. All amounts are NGN.

## 4. Results

All 12 scenarios produced their expected outcome ([summary.txt](evidence/summary.txt)).

### 4.1 Commit and rollback

| Scenario | What happened | Evidence |
| --- | --- | --- |
| S01 COMMIT | Amina's 5,000 transfer committed: 20,000 to 15,000, Tunde 5,000 to 10,000, two ledger legs and an audit record. A finance officer's reversal then posted a new REVERSAL transaction with the legs swapped, restoring both balances while keeping the original. | [S01_commit.txt](evidence/S01_commit.txt) |
| S02 part 1: explicit ROLLBACK | Inside the transaction the session saw 17,000. After ROLLBACK, Amina was back to 20,000 and no TRF-2001 row existed. | [S02_rollback.txt](evidence/S02_rollback.txt) |
| S02 part 2: error | The first transfer (3,000) succeeded and the second (50,000) failed with `insufficient funds ... balance 17000.00`. Every later statement was refused (`current transaction is aborted`), and COMMIT reported `ROLLBACK`. The successful first transfer was undone too: **atomicity**. | same |
| S02 part 3: SAVEPOINT | Kemi's payroll batch paid Amina, Musa and Chiamaka 10,000 each. Musa's payment failed (`account 0012345605 is FROZEN`) and `ROLLBACK TO SAVEPOINT pay_musa` undid only that payment. The batch committed: Kemi 80,000, Amina 30,000, Chiamaka 10,000, Musa 0. | same |

### 4.2 Isolation levels

A finance report reads Amina's balance, then Amina's again and Tunde's, while Amina's app transfers 5,000 to Tunde and commits in between. No money leaves the two accounts, so a correct report totals 25,000.

| Scenario | Amina, first read | Amina, second read | Tunde | Report total | Anomaly |
| --- | --- | --- | --- | --- | --- |
| S03 READ COMMITTED | 20,000 | **15,000** | **10,000** | **30,000** | Non-repeatable read, and read skew: 5,000 counted twice |
| S04 REPEATABLE READ | 20,000 | 20,000 | 5,000 | 25,000 | None: one snapshot for the whole transaction |

S05 shows that PostgreSQL never allows **dirty reads**. While A's 5,000 transfer was uncommitted, B asked for READ UNCOMMITTED (`SHOW transaction_isolation` confirmed `read uncommitted`). B still read 20,000, because PostgreSQL runs READ UNCOMMITTED as READ COMMITTED.

**Conclusion for ClearPay:** reconciliation and end-of-day reports must run under REPEATABLE READ or higher, so that their totals add up. Postings, however, must not use REPEATABLE READ (S09). The right level depends on the workload, not on "higher is safer".

### 4.3 Concurrency problem and control mechanisms

Two ATMs each withdraw 15,000 from Amina's 20,000, half a second apart.

| Scenario | Code and isolation | Outcome | Final balance |
| --- | --- | --- | --- |
| **S06 Problem** | Unlocked check-then-act, READ COMMITTED | Both read 20,000, both passed the check, both posted | **-10,000** |
| **S07 Control 1: row locks** | `post_withdrawal` (FOR UPDATE), READ COMMITTED | B **waited 1.5s** for A's lock, then read 5,000 and was rejected | 5,000 |
| **S08 Control 2: SSI** | Same unlocked code as S06, SERIALIZABLE | B failed with `could not serialize access due to read/write dependencies` (SQLSTATE 40001). B's retry read 5,000 and was rejected | 5,000 |
| **S09 Pitfall** | `post_withdrawal` (FOR UPDATE), REPEATABLE READ, guard off | B waited for the lock, but its snapshot was older than A's commit. Inside B, the balance still showed 5,000 after its own withdrawal, so B never saw A's | **-10,000** |

S06 is a **write-skew / phantom** problem rather than a classic lost update. Each withdrawal *inserts* new ledger rows that change the other's predicate ("posted entries for account 0012345601"), and no existing row is updated by both. That is why row-level conflict detection alone cannot catch it. The Portfolio 1 deferred trigger did not catch it either: it validates each transaction's own entries, not the account's balance.

The S07 MONITOR session captured the lock wait while it was happening:

```text
  pid  | state  | wait_event_type |  wait_event   | blocked_by | query
 92825 | active | Timeout         | PgSleep       | {}         | SELECT pg_sleep(2);
 92827 | active | Lock            | transactionid | {92825}    | SELECT post_withdrawal('req-atm2-7002', ...
```

B (92827) is waiting on A's transaction ID, and `pg_blocking_pids` names A (92825) as the blocker. B already holds the tuple lock on the account row, so it is first in the queue when A finishes.

**Comparing the two controls:**

| | Pessimistic: row locks (S07) | Optimistic: SERIALIZABLE (S08) |
| --- | --- | --- |
| How the conflict is handled | Second request waits | Both run; one is aborted at write or commit time |
| Application work | None; the rejection is a normal business error | Must catch SQLSTATE 40001 and retry the whole transaction |
| Cost under contention | Waiting; throughput on a hot account is one posting at a time | Wasted work and retries; may abort false positives |
| Protects code that forgets to lock | No | Yes: any code path that runs SERIALIZABLE is protected |

**Choice for ClearPay:** row locks in a single posting procedure. The outcome is deterministic, a rejected withdrawal is an ordinary "insufficient funds" rather than a retry loop, and all writes already go through one procedure. SERIALIZABLE is the better choice where many code paths write and none can be trusted to lock. The cost is retry logic in every client.

### 4.4 Deadlock and idempotency

| Scenario | What happened | Evidence |
| --- | --- | --- |
| **S10 Problem: deadlock** | A (Amina to Tunde) locked Amina; B (Tunde to Amina) locked Tunde. Each then requested the other's account. After `deadlock_timeout` (1s), PostgreSQL detected the cycle and aborted A: `ERROR: deadlock detected ... Process 92973 waits for ShareLock on transaction 81374; blocked by process 92994. Process 92994 waits for ShareLock on transaction 81373; blocked by process 92973.` B then committed. | [S10_deadlock.txt](evidence/S10_deadlock.txt) |
| **S11 Control: lock ordering** | The same two transfers through `post_transfer`, which locks both accounts in `account_id` order. B waited for A, then both committed. No deadlock is possible because both sessions request the locks in the same order. | [S11_ordered_locks.txt](evidence/S11_ordered_locks.txt) |
| **S12 Idempotent retry** | Amina's app timed out and resent the same request (key `req-777`) while the first was still running. The retry waited for the account lock, then returned the **same transaction ID** with the notice `idempotency key req-777 was already processed as TRF-777`. Reusing the key for a different amount was rejected. Only one transaction exists, and Amina has 17,500. | [S12_idempotent_retry.txt](evidence/S12_idempotent_retry.txt) |

Without the idempotency check, the retry in S12 would still be blocked by the `ft_idempotency_unique` constraint from Portfolio 1. The client, though, would get a duplicate-key error instead of the transaction ID it needs.

## 5. ACID Summary

| Property | How ClearPay achieves it | Shown in |
| --- | --- | --- |
| Atomicity | All rows of a posting are in one transaction; an error or ROLLBACK removes all of them | S02 |
| Consistency | Constraints and the deferred balanced-entry trigger (Portfolio 1), plus the funds and eligibility checks | S02, S07, Portfolio 1 tests |
| Isolation | Row locks for postings; REPEATABLE READ for reports; SERIALIZABLE as an alternative | S03-S09 |
| Durability | A committed posting is visible to every later connection; PostgreSQL writes the WAL before COMMIT returns | S01 (final state read by a new connection) |

## 6. Limitations

- **Hot accounts serialise.** A busy merchant account can only post one transaction at a time, because every posting locks it. At high volume, a common approach is a stored running balance updated with `UPDATE ... SET balance = balance - x WHERE balance >= x`, or splitting the account into sub-accounts.
- **Timing-based demos.** The sessions are ordered by start offsets and `pg_sleep`, not by a coordination protocol. On a heavily loaded machine the interleaving could differ; the PASS check would then report it.
- **Which session becomes the deadlock victim is not fixed.** The session whose `deadlock_timeout` expires first runs the detector and is aborted. In the saved run that was A.
- **Durability was not tested by crashing the server.** Recovery from the WAL after a crash, and replication to a second server, are covered in Portfolio 5.
- Role permissions are still not set up (as noted in Portfolio 1), so a client could call the unsafe demo functions. In production, clients would be granted EXECUTE on the posting functions only.

## AI Use Declaration

- **Tool used:** Claude Code (Claude Opus 5.5).
- **Used for:** writing the posting procedures, the scenario scripts, the runner and this README.
- **How the output was checked:** every scenario was run against PostgreSQL 15.13, and each timeline was read to confirm that it passed for the stated reason (for example, that B in S08 failed with SQLSTATE 40001, not some other error). One scenario (S09) first produced misleading evidence, because its final check ran before the second session committed. The timing was corrected and the scenario re-run.
