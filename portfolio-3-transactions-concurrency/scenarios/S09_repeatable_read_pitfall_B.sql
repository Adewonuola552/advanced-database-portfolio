\echo 'B: the SAFE post_withdrawal (row locks), under REPEATABLE READ, with the guard switched off for this demo'
SET clearpay.unsafe_allow_repeatable_read = on;
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT post_withdrawal('req-B-9001', 'WDR-B', '0012345601', 15000, 'atm') IS NOT NULL AS posted;
\echo 'B: balance as this transaction''s snapshot sees it, including its own withdrawal'
SELECT balance AS amina_seen_by_B FROM customer_account_balance WHERE account_number = '0012345601';
SELECT pg_sleep(2);
COMMIT;
