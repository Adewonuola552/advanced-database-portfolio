# Portfolio 5: Distributed and Cloud Database Exercise

MIT 8103 Advanced Database Systems, 2026/2027 Academic Session, First Semester Continuous Assessment

Case study: **ClearPay Digital Fintech Platform** (see the [root README](../README.md)). This portfolio runs ClearPay's two databases as real multi-node clusters on one machine. Each script starts the nodes, runs failure and consistency tests against them, records the output, and shuts everything down. Section 5 then turns the results into a cloud deployment design.

| File | What it builds and tests | Evidence |
| --- | --- | --- |
| [pg_replication.sh](pg_replication.sh) | PostgreSQL 15 primary + streaming standby holding the Portfolio 1/3 ledger: replication, lag, sync vs async commit, a blocked commit, crash failover, `pg_rewind` | [pg-replication.txt](evidence/pg-replication.txt) |
| [mongo_replica_set.sh](mongo_replica_set.sh) | MongoDB 7 three-member replica set: write concern, stale secondary reads, election under a running client, loss of majority | [mongo-replica-set.txt](evidence/mongo-replica-set.txt) |
| [mongo_sharding.sh](mongo_sharding.sh) + [statement_lines_export.sql](statement_lines_export.sql) | MongoDB sharded cluster (config server, two shards, mongos) loaded with the full Portfolio 2 dataset: distribution, shard-key routing, shard failure | [mongo-sharding.txt](evidence/mongo-sharding.txt) |

```text
 PostgreSQL (ledger, system of record)       MongoDB replica set (read models, events)
 ┌──────────────┐  WAL stream  ┌──────────┐   ┌─────────┐ oplog ┌─────────┐
 │ node1 :55432 │ ───────────▶ │ node2    │   │ :27201  │──────▶│ :27202  │
 │ primary      │  sync/async  │ :55433   │   │ primary │──────▶│ :27203  │
 └──────────────┘  slot        │ standby  │   └─────────┘       └─────────┘
                               └──────────┘   elections need 2 of 3 votes

 MongoDB sharded cluster
           client ──▶ mongos :27300 ──▶ config server replica set cfg :27301 (chunk map)
                         │
              ┌──────────┴──────────┐
         shard1 :27311          shard2 :27321      accounts {_id: hashed}
                                                   transactions {_id: hashed}
                                                   statement_lines {accountId: hashed}
```

## 1. PostgreSQL Streaming Replication for the Ledger

node2 is created from node1 with `pg_basebackup -R -C -S node2_slot`: a physical copy, a standby configuration, and a replication slot so node1 keeps any WAL that node2 has not yet received. Both nodes use data checksums so that `pg_rewind` can be used later.

| # | Test | Result |
| --- | --- | --- |
| 1 | Replication status | node1 shows node2 `streaming`, `async`; node2 shows `pg_is_in_recovery() = t`, streaming from 55432 through `node2_slot` |
| 2 | Transfer 5,000 on node1, then read on node2 | Both show Amina 15,000, Tunde 10,000 |
| 3 | Run the Portfolio 3 posting procedure on node2 | `ERROR: cannot execute SELECT FOR UPDATE in a read-only transaction`. Standbys serve reads only |
| 4 | **Stale read.** Replay is paused on node2 (standing in for a lagging standby); a 1,000 transfer commits on node1 | node1: Amina **14,000**. node2: Amina **15,000** (stale); `pg_stat_replication` shows 9,624 bytes of WAL not yet applied. After replay resumed, node2 showed 14,000 |
| 5 | **Commit latency**, 500 single-deposit transactions with pgbench | async 0.425 ms; synchronous `remote_write` 0.583 ms; `on` (standby flush) 0.631 ms; `remote_apply` 0.543 ms |
| 6 | **Synchronous replication with the standby down** | The transfer did not return. After 3 s, `pg_stat_activity` showed it waiting on `IPC / SyncRep`. Cancelling gave `WARNING: canceling wait for synchronous replication ... The transaction has already committed locally, but might not have been replicated to the standby.` |
| 7 | **Failover.** node1 killed with `pg_ctl stop -m immediate`; node2 promoted with `pg_promote()` | Writing to node2 before promotion failed (read-only). After promotion: writable in **0.34 s**, timeline 1 → 2. node2 had **all 2,007 transactions and total amount 133,750.00** that node1 had, so RPO = 0. A new transfer succeeded |
| 8 | **Rejoin.** `pg_rewind` node1 against node2, then start it as a standby | `servers diverged at WAL location 0/33F89A0 on timeline 1`, `Done!`. node1 then streamed from node2 and had P5-TRF-5, a transfer written after the failover |

**What the results mean for ClearPay:**

- **Test 4: asynchronous replicas are eventually consistent.** A customer who reads from a replica just after a transfer can see the old balance. Any read that must reflect the customer's own last write ("read your writes") goes to the primary. A report that tolerates seconds of lag can use a replica.
- **Test 5: synchronous replication costs a round trip per commit.** On one machine that is only about 0.1–0.2 ms, and the three synchronous levels are within run-to-run noise of each other. Between availability zones the cost is the network round trip on every commit.
- **Test 6: synchronous replication with a single standby turns the standby into a single point of failure for writes.** This is the consistency-over-availability side of the CAP trade-off. Two details matter:
  1. The cancelled transfer had already committed on node1, even though the client saw a warning.
  2. The fix is two standbys with `synchronous_standby_names = 'ANY 1 (s1, s2)'`. Any one confirmation is enough, so one failure no longer blocks writes, and every commit is still on two servers.
- **Test 7: RPO = 0 depends on synchronous replication.** With asynchronous replication, the transactions in test 4's "not yet applied" gap would have been lost in a crash. The 0.34 s covers promotion only. Detecting the failure and redirecting clients is extra, and in production a tool such as Patroni or a managed service does it.
- **Test 8: the old primary must never accept writes again.** `pg_rewind` removed its divergent WAL so that it could follow the new timeline. Two problems found while building this test are now handled in the script:
  - After `pg_promote()`, an explicit `CHECKPOINT` is needed before `pg_rewind`. Without it, the new primary's control file still showed timeline 1, and `pg_rewind` wrongly reported `no rewind required`.
  - `pg_rewind` copies the source's configuration files, so node1 came back with node2's port and failed to start. Its own settings must be restored afterwards.

## 2. MongoDB Replica Set: Availability and Write Concern

Three voting members, so a majority is 2. 27201 has priority 2 (the preferred primary); `electionTimeoutMillis` is the default 10,000.

| # | Test | Result |
| --- | --- | --- |
| 1 | 300 journaled writes at each write concern | `w: 1` 10.45 ms, `w: "majority"` 11.28 ms, `w: 3` 14.31 ms per write. Waiting for more members costs more; `j: true` forces a journal flush on every write |
| 2 | **Stale read.** 27203 is frozen with `fsyncLock`, then Amina is debited 5,000 with `w: "majority"` | The write succeeded with 2 of 3 members. Reads: primary 15,000, 27202 15,000, **27203 20,000 (stale)**. A `w: 3` write timed out (`WriteConcernFailed`). After unlocking, 27203 showed 15,000 |
| 3 | **Failover under load.** A client writes every 100 ms with `w: "majority"` and retryable writes, and the primary is killed (SIGKILL) | New primary after **10.8 s**. Client: **151 of 151 writes succeeded, 0 failed**. The one write in flight was held for 10.1 s and then completed on the new primary. 151 documents, all with distinct sequence numbers: nothing lost, nothing duplicated |
| 4 | The old primary restarts | It rejoined as a secondary, caught up, and its priority 2 made it primary again |
| 5 | **Loss of majority.** Two of three members killed | The survivor **stepped down to SECONDARY** and writes failed with `NotWritablePrimary`. Reads with `secondaryPreferred` still returned data. When a second member returned, a primary was elected |

**What the results mean for ClearPay:**

- **Test 2: `w: "majority"` is the right write concern for financial data.** A write acknowledged by a majority survives any single failure, because every possible new primary has it. `w: 1` is faster, but a write acknowledged by a primary that then crashes can be rolled back. The stale value on 27203 shows why statement reads should use the primary, or `readConcern: "majority"`, not any secondary.
- **Test 3: availability.** Failover took about the election timeout (10 s) plus the election itself. Retryable writes hid it from the application as one slow request rather than an error. A shorter `electionTimeoutMillis` gives faster failover, but at the risk of needless elections when the network is briefly slow.
- **Test 5: MongoDB chooses consistency over availability in a partition.** A minority cannot elect a primary, so it refuses writes. This is what prevents two primaries (split brain). With PostgreSQL in test 1.6, the operator had to choose; here the voting rule decides automatically.

## 3. MongoDB Sharding: Distribution and Shard Keys

The full Portfolio 2 dataset is loaded through mongos: 30,002 accounts, 534,841 transactions, and 1,037,168 statement lines (one per posted ledger leg). Each collection is hashed and pre-split.

**Distribution:**

| Collection | Shard key | shard1 | shard2 |
| --- | --- | --- | --- |
| accounts | `{_id: "hashed"}` | 50.6% | 49.4% |
| transactions | `{_id: "hashed"}` | 50.2% | 49.8% |
| statement_lines | `{accountId: "hashed"}` | 41.0% | 59.0% |

Hashing a unique `_id` spreads documents almost perfectly. Hashing `accountId` spreads *accounts* evenly, but not *lines*. Portfolio 2's data is skewed: busy merchant accounts have thousands of lines, and all of one account's lines must sit together. This is the **frequency** problem in shard-key choice: a key value that carries much more data than others concentrates load on one shard.

**Routing** (from `explain("executionStats")` through mongos):

| Query | Stage | Shards | Keys / docs examined |
| --- | --- | --- | --- |
| accounts by `_id` (the shard key) | SINGLE_SHARD | 1 | 1 / 1 |
| accounts by `accountNumber` (not the shard key) | SHARD_MERGE | 2 | 1 / 1 |
| transactions by `_id` | SINGLE_SHARD | 1 | 1 / 1 |
| Statement, latest 20, from `transactions` (sharded by `_id`) | SHARD_MERGE_SORT | 2 | 40 / 40: each shard returns 20, mongos keeps 20 |
| Statement, latest 20, from `statement_lines` (sharded by `accountId`) | **SINGLE_SHARD** | **1** | 20 / 20 |
| Monthly report over all transactions | SHARD_MERGE | 2 | 534,841 documents scanned |

The dominant ClearPay read is "statement for one account". With transactions sharded by `_id`, every statement is a scatter-gather: with *n* shards, every shard does the work and mongos merges *n* × 20 results. Copying legs into `statement_lines` sharded by account makes the same query hit one shard. That is the NoSQL pattern of **modelling for the query**, at the cost of storing each leg twice. `accounts` and `statement_lines` hash the same value, so an account and its lines are on the same shard. Reports scan every shard whatever the key, so they belong on secondaries or an analytics copy.

**Shard failure.** shard2 was killed. Each shard here is a single member, so that shard's data became unavailable:

| Request | Result |
| --- | --- |
| Statement for 0000000001 (its lines are on shard1) | OK, 20 lines |
| Statement for 0000000002 (its lines are on shard2) | Failed: `FailedToSatisfyReadPreference` |
| Count all transactions | Failed |
| Find all transactions with `allowPartialResults` | Also failed with `FailedToSatisfyReadPreference` in this test (MongoDB 7.0.2) |

Sharding spreads *load*, not *risk*. Without replication, losing any shard makes part of the data unavailable. In production, each shard and the config server are three-member replica sets (section 2), so a shard survives the loss of one member.

## 4. Consistency and Availability Summary

| Mechanism | Consistency | Availability | Measured |
| --- | --- | --- | --- |
| PostgreSQL async standby | Eventual on the standby; reads can be stale | Primary writes never wait for the standby | 9,624 bytes behind; stale balance |
| PostgreSQL sync standby | Commit confirmed on two servers; RPO = 0 | Writes **block** if the only sync standby is down | +0.1–0.2 ms per commit locally; blocked commit |
| MongoDB `w: "majority"` | Survives any single failure; no rollback | Needs 2 of 3 members; the minority refuses writes | +0.8 ms vs `w: 1`; writes refused at 1 of 3 |
| MongoDB secondary reads | Can be stale | Readable even without a primary | 20,000 vs 15,000 |
| Sharding | Each document lives on exactly one shard | Losing a shard (without replicas) loses its data | Targeted queries survive; scatter-gather fails |

In PACELC terms, both systems are configured as **PC/EC** for the ledger. During a partition (P) they choose consistency over availability (C). Otherwise (E) they accept extra commit latency for consistency (C). Lower latency is only accepted for reads that can tolerate staleness.

## 5. Cloud Deployment Design for ClearPay

The tests above map directly onto managed cloud services:

| Tested locally | Production / cloud equivalent |
| --- | --- |
| node1 + node2, `synchronous_standby_names` | Managed PostgreSQL with a synchronous standby in a second availability zone (for example Amazon RDS Multi-AZ or Azure Database for PostgreSQL with zone-redundant HA), or self-managed PostgreSQL with Patroni |
| `pg_promote()` by hand, `pg_rewind` | Automatic failover and endpoint switch by the managed service or Patroni |
| Paused-replay standby | Asynchronous read replicas for reports and analytics |
| Three-member replica set | Managed MongoDB (for example MongoDB Atlas) with members in three availability zones |
| Two shards + mongos | A sharded cluster when one replica set is no longer enough; each shard is a three-member replica set |

**Proposed architecture:**

1. **Ledger (PostgreSQL):**
   - A primary plus **two** synchronous-candidate standbys in different zones, with `ANY 1`. This keeps RPO = 0 and removes the blocked-commit problem from test 1.6.
   - One asynchronous read replica for finance reports.
   - Continuous WAL archiving to object storage for point-in-time recovery.
   - Postings always go to the primary, because the Portfolio 3 locking requires it.
2. **Read models and events (MongoDB):**
   - A three-zone replica set with `w: "majority"` and `readConcern: "majority"` for customer statements.
   - Shard by account (`statement_lines {accountId: "hashed"}`) only when one replica set's write capacity is exceeded.
   - Monitor busy accounts, because of the 59/41 skew seen in section 3.
3. **Region and data residency:**
   - Latency to Nigerian users and data-protection obligations decide the region. The nearest hyperscale cloud regions are in South Africa.
   - The Nigeria Data Protection Act 2023 and Central Bank of Nigeria rules may require some financial or personal data to stay in Nigeria. This needs confirming with compliance before choosing between an offshore cloud region, in-country facilities, or a hybrid.
   - A cross-region disaster-recovery copy would be **asynchronous**: a synchronous round trip across regions on every posting would be too slow. That copy therefore has an RPO of seconds, not zero.
4. **Security:**
   - Replace the demo's trust authentication with SCRAM passwords and TLS between all nodes.
   - Use private networking only, with encryption at rest.
   - Give applications EXECUTE on the posting functions only (the gap noted in Portfolios 1 and 3).

**Targets, from the measurements:**

| | Ledger (PostgreSQL) | Read models (MongoDB) |
| --- | --- | --- |
| RPO, zone failure | 0 (synchronous standby, test 1.7) | 0 for `w: "majority"` writes |
| RTO, zone failure | Detection + promotion (promotion 0.34 s locally) | About the election timeout (10.8 s measured) |
| RPO, region failure | Seconds (asynchronous cross-region copy) | Seconds |

## 6. How to Reproduce

Requires PostgreSQL 15 (server binaries in `/usr/local/opt/postgresql@15/bin`, or set `PGBIN`), MongoDB 7 with mongosh and the database tools, and, for sharding, the Portfolio 2 database `clearpay_p2`.

```bash
./pg_replication.sh       # about 20 s
./mongo_replica_set.sh    # about 90 s (includes waiting for elections)
./mongo_sharding.sh       # about 75 s (loads 1.6 million documents)
```

Each script deletes and rebuilds its cluster under `.cluster/` (git-ignored), and stops its processes when it exits, including on error. Ports used: 55432-55433, 27201-27203 and 27300-27321.

## 7. Limitations

- **One machine.** Every node shares one disk and one CPU, and the network round trip is microseconds. Latency differences are therefore much smaller than between cloud zones, and only the *direction* of each effect carries over. Real network partitions were simulated by killing or freezing processes.
- **Lag was simulated.** In the PostgreSQL test, replay was paused (`pg_wal_replay_pause`); in the MongoDB test, writes were frozen (`fsyncLock`). Neither is a slow network.
- **Failover was manual in PostgreSQL.** Failure detection and client redirection, the larger part of real RTO, were not built.
- **Single-member shards and config server** keep the sharding demo light. Section 3 shows why production must not do this.
- **No cloud account was used.** Section 5 is a design based on the local evidence, not a deployed system.

## AI Use Declaration

- **Tool used:** Claude Code (Claude Opus 5.5).
- **Used for:** writing the three cluster scripts, the statement-lines export and this README, including the cloud design discussion.
- **How the output was checked:** every script was run end to end, and the evidence files are the actual output. Problems found while running them were fixed and are described above rather than hidden:
  - the missing checkpoint before `pg_rewind`;
  - `pg_rewind` overwriting node1's configuration;
  - psql's exit status stopping the script at an expected error;
  - account sampling that picked accounts from only one shard;
  - `allowPartialResults` not behaving as expected.

  The statements about cloud services and Nigerian regulation are general and should be checked against current provider documentation and compliance advice before they are relied on.
