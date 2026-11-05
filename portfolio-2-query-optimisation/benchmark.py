#!/usr/bin/env python3
"""Measure ClearPay queries before and after indexing, and save the evidence.

Usage: python3 benchmark.py <database>

The database must be freshly loaded with the schema and 01_generate_data.sql, because
the last stage reorders the tables. Any indexes from 03_indexes.sql are dropped first so
that the baseline is clean. Each query runs once to warm the cache, then RUNS more
times, and the median time is reported.
"""

import csv
import hashlib
import json
import re
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVIDENCE = HERE / "evidence"
PLANS = EVIDENCE / "plans"
RUNS = 5
WRITE_RUNS = 15
WRITE_ROWS = 10000


def psql(db, sql, aligned=False):
    """Run SQL through psql and return its output. Raises if any statement fails."""
    args = ["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", db, "-f", "-"]
    if not aligned:
        args.insert(3, "-At")
    done = subprocess.run(args, input=sql, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"psql failed: {done.stderr}\nSQL: {sql[:400]}")
    return done.stdout


def load_queries(path):
    """Split a file on its '-- name: ID | description | label' lines."""
    queries, current = [], None
    for line in path.read_text().splitlines():
        match = re.match(r"-- name: (\S+) \| (.+) \| (.+)$", line)
        if match:
            current = {"id": match[1], "description": match[2], "label": match[3], "sql": ""}
            queries.append(current)
        elif current is not None:
            current["sql"] += line + "\n"
    return queries


def scans(node):
    """Return how each table or index was read, from a JSON plan node."""
    found = []
    target = node.get("Index Name") or node.get("Relation Name")
    if target:
        found.append(f"{node['Node Type']}: {target}")
    for child in node.get("Plans", []):
        found.extend(scans(child))
    return found


def measure(db, query, phase):
    """Return timings and buffers for a query, and save its text plan."""
    sql = query["sql"].rstrip().rstrip(";")
    explain_json = f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql};"
    psql(db, explain_json)  # warm the cache
    runs = [json.loads(psql(db, explain_json))[0] for _ in range(RUNS)]
    last = runs[-1]
    plan = psql(db, f"EXPLAIN (ANALYZE, BUFFERS) {sql};", aligned=True)
    (PLANS / f"{query['id']}_{phase}.txt").write_text(f"{query['description']}\n\n{sql}\n\n{plan}")
    rows = psql(db, f"{sql};")
    return {
        "median_ms": statistics.median(r["Execution Time"] for r in runs),
        "planning_ms": statistics.median(r["Planning Time"] for r in runs),
        "buffers": last["Plan"].get("Shared Hit Blocks", 0) + last["Plan"].get("Shared Read Blocks", 0),
        "row_count": len(rows.splitlines()),
        "scans": "; ".join(dict.fromkeys(scans(last["Plan"]))),
        "hash": hashlib.md5(rows.encode()).hexdigest(),
    }


def write_cost(db, pending_id):
    """Median time to insert WRITE_ROWS ledger entries. Each run is rolled back."""
    psql(db, "VACUUM ledger_entry;")  # clears dead rows left by earlier runs
    sql = f"""
BEGIN;
EXPLAIN (ANALYZE, FORMAT JSON)
INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount, created_at)
SELECT '{pending_id}', a.account_id, 1000 + i, 'DEBIT', 10.00, timestamptz '2026-10-01 00:00+00' + i * interval '1 second'
  FROM generate_series(1, {WRITE_ROWS}) AS i
  JOIN account a ON a.account_number = lpad(i::text, 10, '0');
ROLLBACK;
"""
    times = [json.loads(psql(db, sql))[0]["Execution Time"] for _ in range(WRITE_RUNS + 1)]
    return statistics.median(times[1:])


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    db = sys.argv[1]
    PLANS.mkdir(parents=True, exist_ok=True)

    queries = load_queries(HERE / "02_queries.sql")
    rewrites = load_queries(HERE / "04_rewrites.sql")
    index_sql = (HERE / "03_indexes.sql").read_text()
    index_names = re.findall(r"CREATE INDEX (\w+)", index_sql)

    for name in index_names:
        psql(db, f"DROP INDEX IF EXISTS {name};")
    psql(db, "ANALYZE;")

    ordered = psql(
        db,
        """SELECT abs(correlation) > 0.5 FROM pg_stats
            WHERE tablename = 'ledger_entry' AND attname = 'created_at';""",
    ).strip()
    if ordered == "t":
        sys.exit("The tables were reordered by an earlier run. Load a fresh database first.")

    settings = psql(
        db,
        """SELECT name || ' = ' || setting || coalesce(unit, '') FROM pg_settings
            WHERE name IN ('shared_buffers', 'work_mem', 'jit', 'random_page_cost',
                           'max_parallel_workers_per_gather') ORDER BY name;
           SELECT version();""",
    )
    (EVIDENCE / "server-settings.txt").write_text(settings)

    pending_id = psql(
        db,
        """SELECT transaction_id FROM financial_transaction
            WHERE status = 'PENDING' ORDER BY reference LIMIT 1;""",
    ).strip()

    sizes_before = psql(
        db,
        """SELECT pg_size_pretty(sum(pg_indexes_size(c.oid))) FROM pg_class c
            WHERE c.relname IN ('customer','account','financial_transaction','ledger_entry','audit_log');""",
    ).strip()

    print("baseline...", flush=True)
    before = {q["id"]: measure(db, q, "before") for q in queries}
    write_before = write_cost(db, pending_id)

    print("creating indexes...", flush=True)
    labelled = re.sub(r"(CREATE INDEX (\w+))", r"\\echo \2\n\1", index_sql)
    index_times = psql(db, "\\timing on\n" + labelled + "\n\\echo ANALYZE\nANALYZE;\n", aligned=True)
    (EVIDENCE / "index-build-times.txt").write_text(index_times)

    print("indexed...", flush=True)
    after = {q["id"]: measure(db, q, "after") for q in queries}
    write_after = write_cost(db, pending_id)

    with (EVIDENCE / "benchmark-results.csv").open("w", newline="") as handle:
        out = csv.writer(handle)
        out.writerow(["query", "description", "before_ms", "after_ms", "speedup", "before_buffers",
                      "after_buffers", "rows", "same_results", "before_scans", "after_scans"])
        for q in queries:
            b, a = before[q["id"]], after[q["id"]]
            out.writerow([q["id"], q["description"], f"{b['median_ms']:.2f}", f"{a['median_ms']:.2f}",
                          f"{b['median_ms'] / a['median_ms']:.1f}", b["buffers"], a["buffers"],
                          a["row_count"], b["hash"] == a["hash"], b["scans"], a["scans"]])

    # Rewrites run with the indexes in place.
    print("rewrites...", flush=True)
    r2 = next(q for q in rewrites if q["id"] == "R2a")
    cursor_sql = r2["sql"].rstrip().rstrip(";").replace("LIMIT 50 OFFSET 2000", "LIMIT 1 OFFSET 1999")
    cursor_sql = cursor_sql.replace("SELECT le.created_at, ft.reference, le.entry_type, le.amount", "SELECT le.created_at")
    cursor = psql(db, cursor_sql + ";").strip()
    account_id = psql(db, "SELECT account_id FROM account WHERE account_number = '0000000001';").strip()
    for q in rewrites:
        q["sql"] = q["sql"].replace("{cursor}", cursor).replace("{account_id}", account_id)
    results = {q["id"]: measure(db, q, "rewrite") for q in rewrites}

    with (EVIDENCE / "rewrite-results.csv").open("w", newline="") as handle:
        out = csv.writer(handle)
        out.writerow(["query", "description", "median_ms", "buffers", "rows", "same_as_pair", "scans"])
        for q in rewrites:
            r = results[q["id"]]
            pair = q["label"]
            hashes = {results[o["id"]]["hash"] for o in rewrites if o["label"] == pair}
            out.writerow([q["id"], q["description"], f"{r['median_ms']:.2f}", r["buffers"], r["row_count"],
                          len(hashes) == 1, r["scans"]])

    sizes = psql(
        db,
        f"""SELECT indexrelname AS index_name, relname AS table_name,
                   pg_size_pretty(pg_relation_size(indexrelid)) AS size,
                   pg_relation_size(indexrelid) AS bytes,
                   idx_scan AS times_used
              FROM pg_stat_user_indexes
             WHERE indexrelname IN ({", ".join(f"'{n}'" for n in index_names)})
             ORDER BY bytes DESC;
            SELECT c.relname AS table_name,
                   pg_size_pretty(pg_table_size(c.oid)) AS table_size,
                   pg_size_pretty(pg_indexes_size(c.oid)) AS index_size
              FROM pg_class c
             WHERE c.relname IN ('customer','account','financial_transaction','ledger_entry','audit_log')
             ORDER BY pg_table_size(c.oid) DESC;""",
        aligned=True,
    )
    (EVIDENCE / "index-sizes.txt").write_text(
        f"All indexes on the five tables before adding any: {sizes_before}\n\n{sizes}"
    )

    (EVIDENCE / "write-cost.txt").write_text(
        f"Median time to insert {WRITE_ROWS} ledger entries, rolled back after each of {WRITE_RUNS} timed runs.\n"
        f"Triggers and foreign key checks were active in both phases.\n"
        f"Before indexes: {write_before:.1f} ms\n"
        f"After indexes:  {write_after:.1f} ms\n"
        f"Increase:       {(write_after / write_before - 1) * 100:.0f}%\n"
    )

    # Query output for the portfolio, from the indexed database.
    lines = []
    for q in queries:
        lines.append(f"=== {q['id']}: {q['description']} ({q['label']}) ===\n")
        lines.append(psql(db, q["sql"], aligned=True) + "\n")
    (EVIDENCE / "query-results.txt").write_text("".join(lines))

    # Physical order experiment. The generator inserts rows in random date order, but a
    # real ledger is written chronologically. This stage reorders both tables by date and
    # measures Q5 and Q7 with and without their date indexes. It runs last because it
    # changes the tables, which is why a repeat run needs a freshly loaded database.
    print("physical order experiment...", flush=True)
    correlation_sql = """SELECT tablename, attname, round(correlation::numeric, 3) AS correlation
                           FROM pg_stats
                          WHERE (tablename, attname) IN (('ledger_entry', 'created_at'),
                                                         ('financial_transaction', 'posted_at'))
                          ORDER BY 1;"""
    correlation_before = psql(db, correlation_sql, aligned=True)
    targets = [q for q in queries if q["id"] in ("Q5", "Q7")]

    psql(
        db,
        """CREATE INDEX tmp_ft_created ON financial_transaction (created_at);
           CLUSTER financial_transaction USING tmp_ft_created;
           DROP INDEX tmp_ft_created;
           CLUSTER ledger_entry USING idx_ledger_created;
           ANALYZE financial_transaction;
           ANALYZE ledger_entry;""",
    )
    correlation_after = psql(db, correlation_sql, aligned=True)
    ordered_with = {q["id"]: measure(db, q, "ordered_with_index") for q in targets}
    write_ordered_with = write_cost(db, pending_id)

    psql(db, "DROP INDEX idx_ledger_created; DROP INDEX idx_ft_posted_at; ANALYZE;")
    ordered_without = {q["id"]: measure(db, q, "ordered_no_index") for q in targets}
    write_ordered_without = write_cost(db, pending_id)

    with (EVIDENCE / "physical-order-results.csv").open("w", newline="") as handle:
        out = csv.writer(handle)
        out.writerow(["query", "random_order_no_index_ms", "random_order_with_index_ms",
                      "date_order_no_index_ms", "date_order_with_index_ms", "same_results",
                      "date_order_with_index_scans", "date_order_no_index_scans"])
        for q in targets:
            i = q["id"]
            same = len({before[i]["hash"], after[i]["hash"], ordered_with[i]["hash"], ordered_without[i]["hash"]}) == 1
            out.writerow([i, f"{before[i]['median_ms']:.2f}", f"{after[i]['median_ms']:.2f}",
                          f"{ordered_without[i]['median_ms']:.2f}", f"{ordered_with[i]['median_ms']:.2f}",
                          same, ordered_with[i]["scans"], ordered_without[i]["scans"]])

    (EVIDENCE / "physical-order-correlation.txt").write_text(
        "Correlation between column values and physical row order (1 = perfectly in order).\n\n"
        f"Random insert order:\n{correlation_before}\nAfter reordering by date:\n{correlation_after}\n"
        f"Time to insert {WRITE_ROWS} ledger entries, median of {WRITE_RUNS} rolled-back runs:\n"
        f"With idx_ledger_created:    {write_ordered_with:.1f} ms\n"
        f"Without idx_ledger_created: {write_ordered_without:.1f} ms\n"
    )

    print("done", flush=True)


if __name__ == "__main__":
    main()
