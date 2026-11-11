# advanced-database-portfolio
Assessment Type: Individual Practical Database Portfolio
Submission Platform: LMS + GitHub

## Selected Case Study

**ClearPay Digital Fintech Platform (a simulated organisation).** All five portfolio activities use this case study.

- **Nature of the system:** a fintech platform where customers maintain accounts, deposit and withdraw money, and transfer funds to other customers on the platform.
- **Database users:** customers, customer support officers, finance officers, compliance and audit officers, and system administrators.
- **Major data:** customer profiles, accounts, financial transactions, ledger entries, and audit logs.
- **Key operations:** register customers, create and restrict accounts, check balances, record deposits, withdrawals and transfers, reverse transactions, and audit activity.

## Portfolio Activities

| Portfolio | Activity | What it contains |
| --- | --- | --- |
| [Portfolio 1](portfolio-1-database-design/) | Database Design and Modelling | ER diagram, PostgreSQL schema with constraints and triggers, normalisation, 36 constraint tests |
| [Portfolio 2](portfolio-2-query-optimisation/) | Query Processing and Optimisation | 535,000-transaction workload, execution plans before and after indexing, benchmarks |
| [Portfolio 3](portfolio-3-transactions-concurrency/) | Transactions and Concurrency | Posting procedures; 12 concurrent-session scenarios covering commit, rollback, isolation levels, double spend, locking vs SERIALIZABLE, deadlock and idempotency |
| [Portfolio 4](portfolio-4-nosql/) | NoSQL and Advanced Data Models | MongoDB document, key-value, graph and time-series models; full migration from PostgreSQL, reconciled with `diff` |
| [Portfolio 5](portfolio-5-distributed-cloud/) | Distributed and Cloud Database Exercise | PostgreSQL streaming replication and failover; MongoDB replica set elections and sharding; cloud deployment design |

## Environment

- PostgreSQL 15.13 (Portfolios 1, 2, 3 and 5)
- MongoDB 7.0.2 with mongosh and the MongoDB Database Tools (Portfolios 4 and 5)
- Python 3, standard library only (benchmark and scenario runners)
- macOS; all clusters run locally on one machine

Each portfolio README explains how to reproduce its results. Generated database files (`.mongo-data/`, `.export/`, `.cluster/`) are git-ignored.
