\echo 'B: asks for READ UNCOMMITTED and reads Amina while A''s transfer is uncommitted'
BEGIN ISOLATION LEVEL READ UNCOMMITTED;
SHOW transaction_isolation;
SELECT balance AS amina_seen_by_B FROM customer_account_balance WHERE account_number = '0012345601';
COMMIT;
