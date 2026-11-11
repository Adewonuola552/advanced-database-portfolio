\echo 'A (ATM 1): withdraws 15,000 with post_withdrawal, then holds the transaction open for 2 seconds'
BEGIN;
SELECT post_withdrawal('req-atm1-7001', 'WDR-A', '0012345601', 15000, 'atm-1') IS NOT NULL AS posted;
SELECT pg_sleep(2);
COMMIT;
