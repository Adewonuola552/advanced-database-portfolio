\echo 'B: the same unlocked code as S06, but under SERIALIZABLE'
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT unsafe_withdrawal('WDR-B', '0012345601', 15000, 2);
COMMIT;
\echo 'B: the application treats SQLSTATE 40001 as "retry the whole transaction" and retries once'
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT unsafe_withdrawal('WDR-B-RETRY', '0012345601', 15000, 0);
COMMIT;
SELECT account_number, balance FROM customer_account_balance WHERE account_number = '0012345601';
