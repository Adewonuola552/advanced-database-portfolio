#!/usr/bin/env bash
# Rebuild the ClearPay MongoDB model from PostgreSQL and save all evidence.
# Usage: ./run_all.sh [postgres-database]   (default clearpay_p2, loaded as in Portfolio 2)
set -euo pipefail
cd "$(dirname "$0")"
PGDB=${1:-clearpay_p2}
URI="mongodb://127.0.0.1:27117/clearpay?replicaSet=clearpay-rs"
mkdir -p .export evidence

./start_mongo.sh | tee evidence/00-server.txt

echo "== 1. Export from PostgreSQL ($PGDB)"
{ echo "Source: PostgreSQL database $PGDB"; psql -X -At -d "$PGDB" -c "SELECT version()"
  /usr/bin/time -p psql -X -q -d "$PGDB" -v outdir=.export -f 01_export_from_postgres.sql 2>&1
  wc -l .export/*.json; } > evidence/01-export.txt

echo "== 2. Create collections, validators and indexes"
mongosh --quiet "$URI" 02_setup.js > evidence/02-setup.txt

echo "== 3. Import (validators active)"
for c in customers accounts transactions audit_events; do
    mongoimport --uri "$URI" --collection "$c" --file ".export/$c.json" --numInsertionWorkers 4 2>&1 \
        | sed -E 's/^[0-9T:.+-]+[[:space:]]+//'
done > evidence/03-import.txt

echo "== 4. Reconcile MongoDB against PostgreSQL"
psql -X -q -d "$PGDB" -f 05_reconcile_postgres.sql | sort > .export/summary-postgres.txt
mongosh --quiet "$URI" 05_reconcile_mongo.js | sort > .export/summary-mongo.txt
{ echo "PostgreSQL source and MongoDB copy, summarised in the same format:"; echo
  paste -d '\n' .export/summary-postgres.txt .export/summary-mongo.txt | awk 'NR % 2 { print "PG    " $0; next } { print "MONGO " $0 }'
  echo
  if diff -q .export/summary-postgres.txt .export/summary-mongo.txt >/dev/null; then
      echo "diff: the two summaries are IDENTICAL"
  else
      echo "diff: the summaries differ:"; diff .export/summary-postgres.txt .export/summary-mongo.txt || true
  fi
  mongosh --quiet "$URI" --eval 'var mode = "check"' 05_reconcile_mongo.js
} > evidence/05-reconcile.txt

echo "== 5. Queries, explain plans and other data models"
mongosh --quiet "$URI" 04_queries.js > evidence/04-queries.txt

echo "== 6. Operations and transactions"
mongosh --quiet "$URI" 03_operations.js > evidence/03-operations.txt

grep -H -E "failed to import|MISMATCH|summaries differ" evidence/*.txt || true
echo "Done. Evidence is in evidence/."
