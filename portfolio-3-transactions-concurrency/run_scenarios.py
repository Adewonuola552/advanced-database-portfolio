#!/usr/bin/env python3
"""Run the ClearPay transaction and concurrency scenarios and save the evidence.

Usage: python3 run_scenarios.py [database] [scenario-id ...]

The database (default clearpay_p3) is DROPPED and rebuilt before every scenario from
the Portfolio 1 schema, 01_procedures.sql, 02_fixture.sql and 03_unsafe_demo_functions.sql.

Each session is a separate psql process, so each is a separate database connection.
Sessions start at fixed offsets, and every output line is timestamped as it arrives.
psql echoes each statement before running it (-e), so a statement that blocks on a lock
appears in the timeline before the gap. After the sessions end, a CHECK connection shows
the final state, and a pass/fail query confirms the expected outcome happened.
"""

import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = HERE.parent / "portfolio-1-database-design" / "schema.sql"
SETUP = [SCHEMA, HERE / "01_procedures.sql", HERE / "02_fixture.sql", HERE / "03_unsafe_demo_functions.sql"]
EVIDENCE = HERE / "evidence"

BALANCE = "(SELECT balance FROM customer_account_balance WHERE account_number = '{}')"

SCENARIOS = [
    {
        "id": "S01_commit",
        "title": "COMMIT: a transfer and its reversal are posted and become permanent",
        "sessions": [("A", 0.0)],
        "expect": "Amina 20,000 -> 15,000 after the transfer, back to 20,000 after the reversal; "
                  "both transactions remain in the ledger",
        "pass_sql": f"SELECT {BALANCE.format('0012345601')} = 20000 AND {BALANCE.format('0012345602')} = 5000 "
                    "AND (SELECT count(*) FROM financial_transaction WHERE reference IN ('TRF-1001','REV-TRF-1001') "
                    "AND status = 'POSTED') = 2",
    },
    {
        "id": "S02_rollback",
        "title": "ROLLBACK: explicit rollback, rollback after an error, and partial rollback to a savepoint",
        "sessions": [("A", 0.0)],
        "expect": "TRF-2001, TRF-2002 and TRF-2003 leave no rows; in the payroll batch only the frozen "
                  "account's payment is undone (Kemi 80,000, Amina 30,000, Chiamaka 10,000, Musa 0)",
        "pass_sql": "SELECT NOT EXISTS (SELECT 1 FROM financial_transaction WHERE reference IN ('TRF-2001','TRF-2002','TRF-2003')) "
                    f"AND {BALANCE.format('0012345604')} = 80000 AND {BALANCE.format('0012345601')} = 30000 "
                    f"AND {BALANCE.format('0012345603')} = 10000 AND {BALANCE.format('0012345605')} = 0",
    },
    {
        "id": "S03_read_committed",
        "title": "READ COMMITTED: a report sees a transfer half-way through (non-repeatable read, read skew)",
        "sessions": [("A", 0.0), ("B", 0.7)],
        "expect": "A reads Amina twice and gets 20,000 then 15,000; A's Amina + Tunde total is 30,000, "
                  "although only 25,000 exists in the two accounts",
        "pass_sql": f"SELECT {BALANCE.format('0012345601')} + {BALANCE.format('0012345602')} = 25000",
    },
    {
        "id": "S04_repeatable_read",
        "title": "REPEATABLE READ: the same report sees one consistent snapshot",
        "sessions": [("A", 0.0), ("B", 0.7)],
        "expect": "A reads Amina as 20,000 both times and totals 25,000; a new transaction after COMMIT sees 15,000",
        "pass_sql": f"SELECT {BALANCE.format('0012345601')} = 15000",
    },
    {
        "id": "S05_no_dirty_read",
        "title": "No dirty reads: an uncommitted transfer is invisible, even under READ UNCOMMITTED",
        "sessions": [("A", 0.0), ("B", 0.7)],
        "expect": "B reads Amina as 20,000 while A's 5,000 transfer is uncommitted; A rolls back",
        "pass_sql": f"SELECT {BALANCE.format('0012345601')} = 20000",
    },
    {
        "id": "S06_double_spend",
        "title": "PROBLEM: two concurrent withdrawals both pass an unlocked balance check",
        "sessions": [("A", 0.0), ("B", 0.5)],
        "expect": "Both 15,000 withdrawals from Amina's 20,000 post; balance becomes -10,000",
        "pass_sql": f"SELECT {BALANCE.format('0012345601')} = -10000",
    },
    {
        "id": "S07_row_locks",
        "title": "CONTROL 1: row locks (SELECT ... FOR UPDATE) serialise the two withdrawals",
        "sessions": [("A", 0.0), ("B", 0.5), ("MONITOR", 1.2)],
        "expect": "B waits for A's lock (visible in pg_stat_activity), then reads 5,000 and is rejected; "
                  "balance 5,000",
        "pass_sql": f"SELECT {BALANCE.format('0012345601')} = 5000 "
                    "AND (SELECT count(*) FROM financial_transaction WHERE transaction_type = 'WITHDRAWAL') = 1",
    },
    {
        "id": "S08_serializable",
        "title": "CONTROL 2: SERIALIZABLE detects the double spend in the unlocked code; the retry is rejected",
        "sessions": [("A", 0.0), ("B", 0.5)],
        "expect": "B fails with a serialization failure (SQLSTATE 40001); B's retry reads 5,000 and is "
                  "rejected; balance 5,000",
        "pass_sql": f"SELECT {BALANCE.format('0012345601')} = 5000",
    },
    {
        "id": "S09_repeatable_read_pitfall",
        "title": "PITFALL: under REPEATABLE READ, row locks alone still allow the double spend",
        "sessions": [("A", 0.0), ("B", 0.5), ("C", 4.6)],
        "expect": "With the safety guard switched off, both locked withdrawals post (balance -10,000); "
                  "with the guard on, the procedure refuses to run under REPEATABLE READ",
        "pass_sql": f"SELECT {BALANCE.format('0012345601')} = -10000",
    },
    {
        "id": "S10_deadlock",
        "title": "PROBLEM: opposite transfers that lock accounts in request order deadlock",
        "sessions": [("A", 0.0), ("B", 0.3)],
        "expect": "PostgreSQL detects the deadlock (SQLSTATE 40P01) and aborts one transfer; the other commits",
        "pass_sql": "SELECT (SELECT count(*) FROM financial_transaction WHERE reference IN ('TRF-A','TRF-B')) = 1",
    },
    {
        "id": "S11_ordered_locks",
        "title": "CONTROL: locking in account_id order removes the deadlock",
        "sessions": [("A", 0.0), ("B", 0.3)],
        "expect": "B waits for A, then both transfers commit; balances unchanged overall",
        "pass_sql": "SELECT (SELECT count(*) FROM financial_transaction WHERE reference IN ('TRF-A','TRF-B') "
                    f"AND status = 'POSTED') = 2 AND {BALANCE.format('0012345601')} = 20000",
    },
    {
        "id": "S12_idempotent_retry",
        "title": "Idempotency: a concurrent retry of the same request posts only once",
        "sessions": [("A", 0.0), ("B", 0.3)],
        "expect": "B's retry waits, then returns A's transaction instead of posting again; the same key "
                  "with a different amount is rejected; Amina 17,500",
        "pass_sql": "SELECT (SELECT count(*) FROM financial_transaction WHERE idempotency_key = 'req-777') = 1 "
                    f"AND {BALANCE.format('0012345601')} = 17500",
    },
]


def run(args, **kw):
    done = subprocess.run(args, capture_output=True, text=True, **kw)
    if done.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, args))} failed:\n{done.stderr}")
    return done.stdout


def rebuild(db):
    run(["dropdb", "--if-exists", db])
    run(["createdb", db])
    for path in SETUP:
        run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", db, "-f", str(path)])


def psql_session(db, path):
    """Start psql on a scenario file. Errors do not stop the file, as in a real client."""
    return subprocess.Popen(
        ["psql", "-X", "-e", "-v", "ON_ERROR_STOP=0", "-v", "SHOW_CONTEXT=never",
         "-d", db, "-f", str(path.relative_to(HERE))],
        cwd=HERE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def run_scenario(db, scenario):
    rebuild(db)
    lines, lock = [], threading.Lock()
    t0 = time.monotonic()

    def session(name, offset):
        time.sleep(offset)
        proc = psql_session(db, HERE / "scenarios" / f"{scenario['id']}_{name}.sql")
        for line in proc.stdout:
            with lock:
                lines.append((time.monotonic() - t0, name, line.rstrip("\n")))
        proc.wait()

    threads = [threading.Thread(target=session, args=s) for s in scenario["sessions"]]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    check = run(["psql", "-X", "-d", db, "-f", str((HERE / "scenarios" / "check.sql").relative_to(HERE))], cwd=HERE)
    passed = run(["psql", "-X", "-At", "-d", db, "-c", scenario["pass_sql"]]).strip() == "t"

    width = max(len(name) for name, _ in scenario["sessions"])
    out = [f"Scenario {scenario['id']}: {scenario['title']}",
           f"Expected: {scenario['expect']}",
           f"Result:   {'PASS' if passed else 'FAIL'}",
           "",
           "Sessions: " + ", ".join(f"{n} starts at {o:.1f}s" for n, o in scenario["sessions"]),
           "Each line: seconds since the scenario started | session | psql output",
           "=" * 100]
    out += [f"{t:6.2f}s  {name:<{width}} | {text}" for t, name, text in sorted(lines, key=lambda x: x[0])]
    out += ["=" * 100, "Final state, read by a new connection after all sessions ended:", "", check]
    (EVIDENCE / f"{scenario['id']}.txt").write_text("\n".join(out))
    return passed


def main():
    db = sys.argv[1] if len(sys.argv) > 1 else "clearpay_p3"
    wanted = set(sys.argv[2:])
    EVIDENCE.mkdir(exist_ok=True)

    settings = run(["psql", "-X", "-At", "-d", "postgres", "-c",
                    "SELECT version() UNION ALL "
                    "SELECT name || ' = ' || setting FROM pg_settings "
                    "WHERE name IN ('default_transaction_isolation', 'deadlock_timeout', 'lock_timeout', 'max_connections')"])
    (EVIDENCE / "server-settings.txt").write_text(settings)

    summary = []
    for scenario in SCENARIOS:
        if wanted and scenario["id"] not in wanted:
            continue
        passed = run_scenario(db, scenario)
        summary.append(f"{'PASS' if passed else 'FAIL'}  {scenario['id']:<30} {scenario['expect']}")
        print(summary[-1], flush=True)

    if not wanted:
        (EVIDENCE / "summary.txt").write_text(
            "Expected outcome of each scenario, checked by a query after the sessions ended.\n\n"
            + "\n".join(summary) + "\n")


if __name__ == "__main__":
    main()
