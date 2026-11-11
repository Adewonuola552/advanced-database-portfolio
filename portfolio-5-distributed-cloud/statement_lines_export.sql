-- One document per posted ledger leg, for the sharded statement_lines collection.
-- Usage: psql -X -d <database> -v outdir=<folder> -f statement_lines_export.sql
-- This is ledger_entry with the transaction's reference, type and posting time copied in,
-- so a statement can be read from one collection, sharded by account.

\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\pset pager off

\o :outdir/statement_lines.json
SELECT json_build_object(
           '_id',       json_build_object('$binary', json_build_object('base64', encode(uuid_send(le.entry_id), 'base64'), 'subType', '04')),
           'accountId', json_build_object('$binary', json_build_object('base64', encode(uuid_send(le.account_id), 'base64'), 'subType', '04')),
           'postedAt',  json_build_object('$date', to_char(ft.posted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
           'reference', ft.reference,
           'type',      ft.transaction_type,
           'leg',       le.entry_type,
           'amount',    json_build_object('$numberDecimal', le.amount::TEXT))
  FROM ledger_entry le
  JOIN financial_transaction ft USING (transaction_id)
 WHERE ft.status = 'POSTED';
\o
