\echo 'A (finance report): reads Amina, pauses, then reads Amina again and Tunde, under REPEATABLE READ'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance AS amina_first_read FROM customer_account_balance WHERE account_number = '0012345601' \gset
\echo 'A: amina_first_read =' :amina_first_read
SELECT pg_sleep(2);
SELECT balance AS amina_second_read FROM customer_account_balance WHERE account_number = '0012345601';
SELECT balance AS tunde_read FROM customer_account_balance WHERE account_number = '0012345602' \gset
\echo 'A: tunde_read =' :tunde_read
\echo 'A: report total of the two accounts = amina_first_read + tunde_read (no money left the two accounts, so the true total is 25,000)'
SELECT :amina_first_read + :tunde_read AS reported_total;
COMMIT;
\echo 'A: a new transaction after COMMIT'
SELECT account_number, balance FROM customer_account_balance WHERE account_number IN ('0012345601', '0012345602') ORDER BY 1;
