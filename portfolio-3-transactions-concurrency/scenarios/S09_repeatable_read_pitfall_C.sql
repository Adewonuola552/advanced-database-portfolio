\echo 'C: after both commit, the balance is negative'
SELECT account_number, balance FROM customer_account_balance WHERE account_number = '0012345601';
\echo 'C: with the guard on (the normal setting), the procedure refuses REPEATABLE READ'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT post_withdrawal('req-C-9003', 'WDR-C', '0012345602', 100, 'atm') IS NOT NULL AS posted;
ROLLBACK;
