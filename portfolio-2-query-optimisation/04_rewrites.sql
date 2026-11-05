-- Same question, two ways of writing it. These run with the indexes in place. Each
-- pair must return identical rows, which benchmark.py checks.
-- {cursor} is replaced with the date of the 2,000th row in R2, the point the user has
-- reached when paging through a statement. {account_id} is replaced with the busiest
-- account's ID in R4.

-- name: R1a | Filter that wraps the column in a cast (index unusable) | R1
SELECT count(*) AS transactions, sum(amount) AS total_amount
  FROM financial_transaction
 WHERE status = 'POSTED'
   AND (posted_at AT TIME ZONE 'UTC')::date = date '2026-03-15';

-- name: R1b | Same filter as a range on the bare column | R1
SELECT count(*) AS transactions, sum(amount) AS total_amount
  FROM financial_transaction
 WHERE status = 'POSTED'
   AND posted_at >= timestamptz '2026-03-15 00:00+00'
   AND posted_at <  timestamptz '2026-03-16 00:00+00';

-- name: R2a | Deep page of a statement using OFFSET | R2
SELECT le.created_at, ft.reference, le.entry_type, le.amount
  FROM account a
  JOIN ledger_entry le ON le.account_id = a.account_id
  JOIN financial_transaction ft ON ft.transaction_id = le.transaction_id
 WHERE a.account_number = '0000000001'
   AND ft.status = 'POSTED'
 ORDER BY le.created_at DESC
 LIMIT 50 OFFSET 2000;

-- name: R2b | Same page using keyset pagination | R2
SELECT le.created_at, ft.reference, le.entry_type, le.amount
  FROM account a
  JOIN ledger_entry le ON le.account_id = a.account_id
  JOIN financial_transaction ft ON ft.transaction_id = le.transaction_id
 WHERE a.account_number = '0000000001'
   AND ft.status = 'POSTED'
   AND le.created_at < timestamptz '{cursor}'
 ORDER BY le.created_at DESC
 LIMIT 50;

-- name: R3a | Customer search with lower() on the column (index unusable) | R3
SELECT customer_id, first_name, last_name, email
  FROM customer
 WHERE lower(email) = 'customer00123@example.com';

-- name: R3b | Same search by exact value, using the unique index | R3
SELECT customer_id, first_name, last_name, email
  FROM customer
 WHERE email = 'customer00123@example.com';

-- name: R4a | Busiest account's statement, joining from account number | R4
SELECT le.created_at, ft.reference, ft.transaction_type, le.entry_type, le.amount
  FROM account a
  JOIN ledger_entry le ON le.account_id = a.account_id
  JOIN financial_transaction ft ON ft.transaction_id = le.transaction_id
 WHERE a.account_number = '0000000001'
   AND ft.status = 'POSTED'
 ORDER BY le.created_at DESC
 LIMIT 50;

-- name: R4b | Same statement with the account ID known at planning time | R4
SELECT le.created_at, ft.reference, ft.transaction_type, le.entry_type, le.amount
  FROM ledger_entry le
  JOIN financial_transaction ft ON ft.transaction_id = le.transaction_id
 WHERE le.account_id = '{account_id}'
   AND ft.status = 'POSTED'
 ORDER BY le.created_at DESC
 LIMIT 50;
