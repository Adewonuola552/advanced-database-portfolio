\echo 'A: starts a 5,000 transfer from Amina, waits 2 seconds without committing, then rolls back'
BEGIN;
SELECT post_transfer('req-5001', 'TRF-5001', '0012345601', '0012345602', 5000, 'amina.mobile-app') IS NOT NULL AS posted;
SELECT balance AS amina_seen_by_A FROM customer_account_balance WHERE account_number = '0012345601';
SELECT pg_sleep(2);
ROLLBACK;
