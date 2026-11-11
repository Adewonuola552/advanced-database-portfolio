\echo 'B (ATM 2): withdraws 15,000 from the same account at the same time'
BEGIN;
SELECT post_withdrawal('req-atm2-7002', 'WDR-B', '0012345601', 15000, 'atm-2') IS NOT NULL AS posted;
COMMIT;
SELECT account_number, balance FROM customer_account_balance WHERE account_number = '0012345601';
