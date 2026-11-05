-- ClearPay synthetic workload for query optimisation. All data is simulated.
-- Run on a new database after portfolio-1-database-design/schema.sql.
--
-- Scale: 20,000 customers, 30,000 customer accounts, about 535,000 transactions,
-- about 1,040,000 ledger entries and 100,000 audit records, over two years.
--
-- The Portfolio 1 triggers stay enabled, so every posted transaction is validated
-- at COMMIT. Activity is skewed: a few "hot" accounts send many transfers, as busy
-- merchant accounts would, while most send few. This lets the tests compare
-- selective and unselective lookups.

\set ON_ERROR_STOP on

BEGIN;

SELECT setseed(0.2026);

-- Customers -------------------------------------------------------------------
INSERT INTO customer (first_name, last_name, email, phone, created_at)
SELECT 'First' || i,
       'Last' || i,
       'customer' || lpad(i::text, 5, '0') || '@example.com',
       '+23480' || lpad(i::text, 8, '0'),
       timestamptz '2024-01-01 00:00+00' + (i % 300) * interval '1 day'
  FROM generate_series(1, 20000) AS i;

-- Accounts: every customer has one, and the first 10,000 customers have a second.
-- Every tenth account is USD. Account numbers keep leading zeroes.
CREATE TEMP TABLE account_plan ON COMMIT DROP AS
SELECT i AS account_no,
       ((i - 1) % 20000) + 1 AS customer_no,
       CASE WHEN i % 10 = 0 THEN 'USD' ELSE 'NGN' END AS currency_code
  FROM generate_series(1, 30000) AS i;

INSERT INTO account (customer_id, account_number, account_kind, currency_code, created_at)
SELECT c.customer_id, lpad(p.account_no::text, 10, '0'), 'CUSTOMER', p.currency_code, c.created_at
  FROM account_plan p
  JOIN customer c ON c.email = 'customer' || lpad(p.customer_no::text, 5, '0') || '@example.com';

INSERT INTO account (account_number, account_kind, currency_code, created_at) VALUES
    ('INT-NGN-01', 'INTERNAL', 'NGN', timestamptz '2024-01-01 00:00+00'),
    ('INT-USD-01', 'INTERNAL', 'USD', timestamptz '2024-01-01 00:00+00');

-- Numbered within each currency, so that pairs can be picked in the same currency.
CREATE TEMP TABLE account_pick ON COMMIT DROP AS
SELECT account_id,
       currency_code,
       row_number() OVER (PARTITION BY currency_code ORDER BY account_number) - 1 AS pick_no
  FROM account
 WHERE account_kind = 'CUSTOMER';
CREATE UNIQUE INDEX ON account_pick (currency_code, pick_no);
ANALYZE account_pick;

CREATE TEMP TABLE internal_account ON COMMIT DROP AS
SELECT currency_code, account_id FROM account WHERE account_kind = 'INTERNAL';

CREATE TEMP TABLE currency_size ON COMMIT DROP AS
SELECT currency_code, count(*) AS n FROM account_pick GROUP BY currency_code;

-- Transaction plan ------------------------------------------------------------
-- Random draws are stored first so each row keeps one consistent set of values.
CREATE TEMP TABLE raw_draw ON COMMIT DROP AS
SELECT i,
       CASE WHEN random() < 0.10 THEN 'USD' ELSE 'NGN' END AS currency_code,
       random() AS r_type,
       random() AS r_status,
       random() AS r_source,   -- squared below to skew activity towards hot accounts
       random() AS r_dest,
       random() AS r_amount,
       random() AS r_time
  FROM generate_series(1, 500000) AS i;

-- Account picks are stored as plain columns and the table is analysed. Joining on
-- calculated values from an unanalysed table gave the planner a very poor plan: the
-- first version of this script was still on the next step after six minutes.
CREATE TEMP TABLE draw ON COMMIT DROP AS
SELECT r.*,
       floor(z.n * r.r_source ^ 2)::bigint AS source_pick,
       floor(z.n * r.r_dest)::bigint AS dest_pick,
       (floor(z.n * r.r_dest)::bigint + 1) % z.n AS alt_pick
  FROM raw_draw r
  JOIN currency_size z USING (currency_code);
ANALYZE draw;

CREATE TEMP TABLE tx_plan ON COMMIT DROP AS
SELECT gen_random_uuid() AS transaction_id,
       d.i,
       d.currency_code,
       CASE WHEN d.r_type < 0.70 THEN 'TRANSFER'
            WHEN d.r_type < 0.88 THEN 'DEPOSIT'
            ELSE 'WITHDRAWAL' END AS transaction_type,
       CASE WHEN d.r_status < 0.002 THEN 'PENDING'
            WHEN d.r_status < 0.032 THEN 'FAILED'
            ELSE 'POSTED' END AS final_status,
       round((CASE WHEN d.currency_code = 'USD' THEN 10 ELSE 100 END
              * (1 + d.r_amount ^ 3 * 500))::numeric, 2) AS amount,
       timestamptz '2024-11-01 00:00+00' + d.r_time * interval '730 days' AS created_at,
       s.account_id AS source_account,
       -- Uses the next account when the draw would make a transfer to itself.
       CASE WHEN x.account_id = s.account_id THEN y.account_id ELSE x.account_id END AS dest_account,
       ia.account_id AS internal_account
  FROM draw d
  JOIN account_pick s ON s.currency_code = d.currency_code AND s.pick_no = d.source_pick
  JOIN account_pick x ON x.currency_code = d.currency_code AND x.pick_no = d.dest_pick
  JOIN account_pick y ON y.currency_code = d.currency_code AND y.pick_no = d.alt_pick
  JOIN internal_account ia ON ia.currency_code = d.currency_code;

-- Transactions start as PENDING, as they would in the application.
INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type,
                                   amount, currency_code, created_at)
SELECT transaction_id, 'TXN' || lpad(i::text, 8, '0'), 'idem-txn-' || i, transaction_type,
       amount, currency_code, created_at
  FROM tx_plan;

-- Debit line. FAILED transactions have no entries, so they have no financial effect.
INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount, created_at)
SELECT transaction_id,
       CASE transaction_type WHEN 'DEPOSIT' THEN internal_account ELSE source_account END,
       1, 'DEBIT', amount, created_at
  FROM tx_plan
 WHERE final_status <> 'FAILED';

-- Credit line.
INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount, created_at)
SELECT transaction_id,
       CASE transaction_type
           WHEN 'TRANSFER' THEN dest_account
           WHEN 'DEPOSIT' THEN source_account
           ELSE internal_account END,
       2, 'CREDIT', amount, created_at
  FROM tx_plan
 WHERE final_status <> 'FAILED';

-- Opening deposits, large enough that no generated activity overdraws an account.
-- The schema does not enforce sufficient funds yet (planned for Portfolio 3), so the
-- final check below confirms this.
CREATE TEMP TABLE opening_plan ON COMMIT DROP AS
SELECT gen_random_uuid() AS transaction_id,
       row_number() OVER (ORDER BY p.currency_code, p.pick_no) AS i,
       p.account_id,
       p.currency_code,
       ia.account_id AS internal_account,
       CASE WHEN p.currency_code = 'USD' THEN 50000000.00 ELSE 500000000.00 END AS amount,
       timestamptz '2024-10-01 00:00+00' AS created_at
  FROM account_pick p
  JOIN internal_account ia USING (currency_code);

INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type,
                                   amount, currency_code, created_at)
SELECT transaction_id, 'OPEN' || lpad(i::text, 8, '0'), 'idem-open-' || i, 'DEPOSIT',
       amount, currency_code, created_at
  FROM opening_plan;

INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount, created_at)
SELECT transaction_id, internal_account, 1, 'DEBIT', amount, created_at FROM opening_plan
UNION ALL
SELECT transaction_id, account_id, 2, 'CREDIT', amount, created_at FROM opening_plan;

-- About 1% of posted transfers are fully reversed by a linked transaction.
CREATE TEMP TABLE reversal_plan ON COMMIT DROP AS
SELECT gen_random_uuid() AS transaction_id,
       row_number() OVER (ORDER BY i) AS rev_no,
       transaction_id AS original_id,
       source_account,
       dest_account,
       amount,
       currency_code,
       created_at + interval '2 days' AS created_at
  FROM tx_plan
 WHERE transaction_type = 'TRANSFER'
   AND final_status = 'POSTED'
   AND i % 70 = 0;

INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type,
                                   amount, currency_code, reversal_of_transaction_id, created_at)
SELECT transaction_id, 'REV' || lpad(rev_no::text, 8, '0'), 'idem-rev-' || rev_no, 'REVERSAL',
       amount, currency_code, original_id, created_at
  FROM reversal_plan;

INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount, created_at)
SELECT transaction_id, dest_account, 1, 'DEBIT', amount, created_at FROM reversal_plan
UNION ALL
SELECT transaction_id, source_account, 2, 'CREDIT', amount, created_at FROM reversal_plan;

-- Move statuses to their final values. The deferred trigger validates each posted
-- transaction at COMMIT.
UPDATE financial_transaction ft
   SET status = 'POSTED', posted_at = ft.created_at + interval '5 seconds'
  FROM tx_plan p
 WHERE ft.transaction_id = p.transaction_id AND p.final_status = 'POSTED';

UPDATE financial_transaction ft
   SET status = 'FAILED'
  FROM tx_plan p
 WHERE ft.transaction_id = p.transaction_id AND p.final_status = 'FAILED';

UPDATE financial_transaction ft
   SET status = 'POSTED', posted_at = ft.created_at + interval '5 seconds'
  FROM opening_plan p
 WHERE ft.transaction_id = p.transaction_id;

UPDATE financial_transaction ft
   SET status = 'POSTED', posted_at = ft.created_at + interval '5 seconds'
  FROM reversal_plan p
 WHERE ft.transaction_id = p.transaction_id;

-- Audit records: one per reversal, the rest are general support and system events.
INSERT INTO audit_log (transaction_id, actor_identifier, action, details, created_at)
SELECT transaction_id, 'finance.officer' || lpad((rev_no % 20 + 1)::text, 2, '0'),
       'REVERSAL_AUTHORISED',
       jsonb_build_object('ticket', 'TCK-' || lpad(rev_no::text, 6, '0'), 'reason', 'customer dispute'),
       created_at
  FROM reversal_plan;

INSERT INTO audit_log (actor_identifier, action, details, created_at)
SELECT 'support.agent' || lpad((i % 50 + 1)::text, 2, '0'),
       (ARRAY['LOGIN', 'ACCOUNT_VIEWED', 'COMPLAINT_OPENED', 'COMPLAINT_CLOSED'])[i % 4 + 1],
       jsonb_build_object('ticket', 'SUP-' || lpad(i::text, 6, '0'),
                          'channel', (ARRAY['web', 'mobile', 'phone'])[i % 3 + 1]),
       timestamptz '2024-11-01 00:00+00' + (i % 730) * interval '1 day'
  FROM generate_series(1, 100000 - (SELECT count(*) FROM reversal_plan)) AS i;

COMMIT;

-- Reclaims the space left by the status updates, then refreshes planner statistics.
VACUUM (FULL, ANALYZE);

-- Checks ----------------------------------------------------------------------
\echo '=== Row counts ==='
SELECT 'customer' AS table_name, count(*) AS row_count FROM customer
UNION ALL SELECT 'account', count(*) FROM account
UNION ALL SELECT 'financial_transaction', count(*) FROM financial_transaction
UNION ALL SELECT 'ledger_entry', count(*) FROM ledger_entry
UNION ALL SELECT 'audit_log', count(*) FROM audit_log;

\echo '=== Transactions by status ==='
SELECT status, count(*) AS transactions FROM financial_transaction GROUP BY status ORDER BY status;

\echo '=== Lowest customer balance (expected: not negative) ==='
SELECT min(balance) AS lowest_balance FROM customer_account_balance;

\echo '=== Whole-ledger check by currency: posted debits minus posted credits (expected: 0) ==='
SELECT ft.currency_code,
       sum(CASE WHEN le.entry_type = 'DEBIT' THEN le.amount ELSE -le.amount END) AS debits_minus_credits
  FROM ledger_entry le
  JOIN financial_transaction ft USING (transaction_id)
 WHERE ft.status = 'POSTED'
 GROUP BY ft.currency_code
 ORDER BY ft.currency_code;

\echo '=== Debits sent per account: how skewed the activity is ==='
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY debits) AS median_account,
       max(debits) AS busiest_account
  FROM (SELECT account_id, count(*) AS debits
          FROM ledger_entry le
          JOIN account a USING (account_id)
         WHERE entry_type = 'DEBIT' AND a.account_kind = 'CUSTOMER'
         GROUP BY account_id) s;
