-- Export the ClearPay relational data as MongoDB documents (one JSON document per line).
-- Read-only on the source: it only creates temporary functions.
--
-- Usage: psql -X -d <database> -v outdir=<folder> -f 01_export_from_postgres.sql
-- The source is a database loaded as in Portfolio 2 (Portfolio 1 schema +
-- portfolio-2-query-optimisation/01_generate_data.sql).
--
-- Values use MongoDB Extended JSON so that types survive the import:
--   UUID        -> {"$binary": {"base64": ..., "subType": "04"}}   (BSON UUID, 16 bytes)
--   NUMERIC     -> {"$numberDecimal": "..."}                       (Decimal128: exact money)
--   TIMESTAMPTZ -> {"$date": "...Z"}                               (BSON date, UTC)

\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\pset pager off

CREATE FUNCTION pg_temp.ej_uuid(u UUID) RETURNS JSON LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN u IS NULL THEN NULL ELSE
        json_build_object('$binary', json_build_object('base64', encode(uuid_send(u), 'base64'), 'subType', '04'))
    END $$;
CREATE FUNCTION pg_temp.ej_dec(n NUMERIC) RETURNS JSON LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN n IS NULL THEN NULL ELSE json_build_object('$numberDecimal', n::TEXT) END $$;
CREATE FUNCTION pg_temp.ej_date(t TIMESTAMPTZ) RETURNS JSON LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN t IS NULL THEN NULL ELSE
        json_build_object('$date', to_char(t AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))
    END $$;

-- customers: profile + embedded summary of the customer's accounts (subset pattern) -----
\o :outdir/customers.json
SELECT json_build_object(
           '_id',       pg_temp.ej_uuid(c.customer_id),
           'firstName', c.first_name,
           'lastName',  c.last_name,
           'email',     c.email,
           'phone',     c.phone,
           'createdAt', pg_temp.ej_date(c.created_at),
           'accounts',  (SELECT json_agg(json_build_object(
                                    'accountId',     pg_temp.ej_uuid(a.account_id),
                                    'accountNumber', a.account_number,
                                    'currency',      a.currency_code,
                                    'status',        a.status) ORDER BY a.account_number)
                           FROM account a WHERE a.customer_id = c.customer_id))
  FROM customer c;

-- accounts: with a stored balance computed from posted ledger entries -------------------
\o :outdir/accounts.json
WITH posted AS (
    SELECT le.account_id,
           sum(CASE WHEN le.entry_type = 'CREDIT' THEN le.amount ELSE -le.amount END) AS balance,
           max(ft.posted_at) AS last_posted_at
      FROM ledger_entry le
      JOIN financial_transaction ft USING (transaction_id)
     WHERE ft.status = 'POSTED'
     GROUP BY le.account_id
)
SELECT json_strip_nulls(json_build_object(
           '_id',           pg_temp.ej_uuid(a.account_id),
           'accountNumber', a.account_number,
           'kind',          a.account_kind,
           'currency',      a.currency_code,
           'status',        a.status,
           -- extended reference: the owner's name is copied so a statement needs no join
           'customer',      CASE WHEN c.customer_id IS NOT NULL THEN json_build_object(
                                'customerId', pg_temp.ej_uuid(c.customer_id),
                                'name',       c.first_name || ' ' || c.last_name) END,
           'balance',       pg_temp.ej_dec(coalesce(p.balance, 0)::NUMERIC(18,2)),
           'createdAt',     pg_temp.ej_date(a.created_at),
           'updatedAt',     pg_temp.ej_date(coalesce(p.last_posted_at, a.created_at))))
  FROM account a
  LEFT JOIN customer c USING (customer_id)
  LEFT JOIN posted p USING (account_id);

-- transactions: one document per business transaction, ledger legs embedded -------------
\o :outdir/transactions.json
SELECT json_strip_nulls(json_build_object(
           '_id',            pg_temp.ej_uuid(ft.transaction_id),
           'reference',      ft.reference,
           'idempotencyKey', ft.idempotency_key,
           'type',           ft.transaction_type,
           'amount',         pg_temp.ej_dec(ft.amount),
           'currency',       ft.currency_code,
           'status',         ft.status,
           'reversalOf',     pg_temp.ej_uuid(ft.reversal_of_transaction_id),
           'createdAt',      pg_temp.ej_date(ft.created_at),
           'postedAt',       pg_temp.ej_date(ft.posted_at),
           -- failed transactions keep an empty list (json_strip_nulls removes nulls only)
           'entries',        coalesce(e.entries, '[]'::JSON)))
  FROM financial_transaction ft
  LEFT JOIN LATERAL (
        SELECT json_agg(json_build_object(
                   'line',          le.line_number,
                   'accountId',     pg_temp.ej_uuid(le.account_id),
                   'accountNumber', a.account_number,
                   'type',          le.entry_type,
                   'amount',        pg_temp.ej_dec(le.amount)) ORDER BY le.line_number) AS entries
          FROM ledger_entry le JOIN account a USING (account_id)
         WHERE le.transaction_id = ft.transaction_id) e ON true;

-- audit_events: time-series measurements; actor and action are the series metadata ------
\o :outdir/audit_events.json
SELECT json_strip_nulls(json_build_object(
           '_id',           pg_temp.ej_uuid(audit_id),
           'at',            pg_temp.ej_date(created_at),
           'meta',          json_build_object('actor', actor_identifier, 'action', action),
           'transactionId', pg_temp.ej_uuid(transaction_id),
           'details',       details))
  FROM audit_log
 ORDER BY created_at;  -- time order: out-of-order inserts fragment time-series buckets (see Q5)

\o
