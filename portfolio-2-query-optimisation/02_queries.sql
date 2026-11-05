-- ClearPay business queries. Each "-- name:" line starts a query that benchmark.py
-- times. These can also be pasted directly into psql.
-- Dates and identifiers are fixed so that runs can be compared.

-- name: Q1 | Customer statement, typical account | Customer
SELECT le.created_at, ft.reference, ft.transaction_type, le.entry_type, le.amount
  FROM account a
  JOIN ledger_entry le ON le.account_id = a.account_id
  JOIN financial_transaction ft ON ft.transaction_id = le.transaction_id
 WHERE a.account_number = '0000015001'
   AND ft.status = 'POSTED'
   AND le.created_at >= timestamptz '2026-01-01 00:00+00'
   AND le.created_at <  timestamptz '2026-07-01 00:00+00'
 ORDER BY le.created_at DESC
 LIMIT 50;

-- name: Q2 | Customer statement, busiest account | Customer
SELECT le.created_at, ft.reference, ft.transaction_type, le.entry_type, le.amount
  FROM account a
  JOIN ledger_entry le ON le.account_id = a.account_id
  JOIN financial_transaction ft ON ft.transaction_id = le.transaction_id
 WHERE a.account_number = '0000000001'
   AND ft.status = 'POSTED'
   AND le.created_at >= timestamptz '2026-01-01 00:00+00'
   AND le.created_at <  timestamptz '2026-07-01 00:00+00'
 ORDER BY le.created_at DESC
 LIMIT 50;

-- name: Q3 | Current balance of one account | Customer
SELECT account_number, currency_code, balance
  FROM customer_account_balance
 WHERE account_number = '0000015001';

-- name: Q4 | Latest transactions across a customer's accounts | Customer support
SELECT a.account_number, le.created_at, ft.reference, ft.status, le.entry_type, le.amount
  FROM customer c
  JOIN account a ON a.customer_id = c.customer_id
  JOIN ledger_entry le ON le.account_id = a.account_id
  JOIN financial_transaction ft ON ft.transaction_id = le.transaction_id
 WHERE c.email = 'customer00123@example.com'
 ORDER BY le.created_at DESC
 LIMIT 20;

-- name: Q5 | Daily reconciliation totals for one month | Finance
SELECT (ft.posted_at AT TIME ZONE 'UTC')::date AS posting_date,
       ft.transaction_type,
       ft.currency_code,
       count(*) AS transactions,
       sum(ft.amount) AS total_amount
  FROM financial_transaction ft
 WHERE ft.status = 'POSTED'
   AND ft.posted_at >= timestamptz '2026-03-01 00:00+00'
   AND ft.posted_at <  timestamptz '2026-04-01 00:00+00'
 GROUP BY 1, 2, 3
 ORDER BY 1, 2, 3;

-- name: Q6 | Oldest transactions stuck in PENDING | Customer support
SELECT reference, transaction_type, amount, currency_code, created_at
  FROM financial_transaction
 WHERE status = 'PENDING'
   AND created_at < timestamptz '2026-10-01 00:00+00'
 ORDER BY created_at
 LIMIT 100;

-- name: Q7 | Top 10 customer accounts by value sent in one month | Finance
SELECT a.account_number,
       a.currency_code,
       count(*) AS debits,
       sum(le.amount) AS value_sent
  FROM ledger_entry le
  JOIN financial_transaction ft ON ft.transaction_id = le.transaction_id
  JOIN account a ON a.account_id = le.account_id
 WHERE le.entry_type = 'DEBIT'
   AND ft.status = 'POSTED'
   AND a.account_kind = 'CUSTOMER'
   AND le.created_at >= timestamptz '2026-03-01 00:00+00'
   AND le.created_at <  timestamptz '2026-04-01 00:00+00'
 GROUP BY a.account_number, a.currency_code
 ORDER BY value_sent DESC, a.account_number
 LIMIT 10;

-- name: Q8 | Find audit records by ticket inside JSONB details | Compliance
SELECT actor_identifier, action, details, created_at
  FROM audit_log
 WHERE details @> '{"ticket": "SUP-012345"}'
 ORDER BY created_at DESC, audit_id;

-- name: Q9 | Whole-ledger audit for unbalanced posted transactions | Compliance
SELECT ft.reference,
       sum(CASE WHEN le.entry_type = 'DEBIT' THEN le.amount ELSE -le.amount END) AS difference
  FROM financial_transaction ft
  JOIN ledger_entry le ON le.transaction_id = ft.transaction_id
 WHERE ft.status = 'POSTED'
 GROUP BY ft.reference
HAVING sum(CASE WHEN le.entry_type = 'DEBIT' THEN le.amount ELSE -le.amount END) <> 0
 ORDER BY ft.reference;
