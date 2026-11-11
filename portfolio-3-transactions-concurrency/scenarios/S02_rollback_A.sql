\echo '=== Part 1: explicit ROLLBACK. Amina starts a 3,000 transfer to Chiamaka, then cancels it.'
BEGIN;
SELECT post_transfer('req-2001', 'TRF-2001', '0012345601', '0012345603', 3000, 'amina.mobile-app') IS NOT NULL AS posted;
\echo '--- Inside the transaction the transfer is visible to this session'
SELECT account_number, balance FROM customer_account_balance WHERE account_number IN ('0012345601', '0012345603') ORDER BY 1;
ROLLBACK;
\echo '--- After ROLLBACK: balances restored, and no transaction row exists'
SELECT account_number, balance FROM customer_account_balance WHERE account_number IN ('0012345601', '0012345603') ORDER BY 1;
SELECT count(*) AS rows_for_trf_2001 FROM financial_transaction WHERE reference = 'TRF-2001';

\echo '=== Part 2: an error aborts the whole transaction. The first transfer succeeds, the second exceeds the balance.'
BEGIN;
SELECT post_transfer('req-2002', 'TRF-2002', '0012345601', '0012345603', 3000, 'amina.mobile-app') IS NOT NULL AS posted;
SELECT post_transfer('req-2003', 'TRF-2003', '0012345601', '0012345602', 50000, 'amina.mobile-app') IS NOT NULL AS posted;
\echo '--- Every later statement is refused until the transaction ends'
SELECT 1;
\echo '--- COMMIT on an aborted transaction performs a ROLLBACK'
COMMIT;
SELECT account_number, balance FROM customer_account_balance WHERE account_number IN ('0012345601', '0012345602', '0012345603') ORDER BY 1;
SELECT count(*) AS rows_for_trf_2002_or_2003 FROM financial_transaction WHERE reference IN ('TRF-2002', 'TRF-2003');

\echo '=== Part 3: SAVEPOINT. Kemi pays three staff 10,000 each in one batch. Musa''s account is FROZEN.'
\echo '    Only Musa''s payment is rolled back; the batch still commits the other two.'
BEGIN;
SAVEPOINT pay_amina;
SELECT post_transfer('pay-2026-11-amina', 'PAY-AMINA', '0012345604', '0012345601', 10000, 'kemi.payroll') IS NOT NULL AS posted;
RELEASE SAVEPOINT pay_amina;
SAVEPOINT pay_musa;
SELECT post_transfer('pay-2026-11-musa', 'PAY-MUSA', '0012345604', '0012345605', 10000, 'kemi.payroll') IS NOT NULL AS posted;
ROLLBACK TO SAVEPOINT pay_musa;
SAVEPOINT pay_chiamaka;
SELECT post_transfer('pay-2026-11-chiamaka', 'PAY-CHIAMAKA', '0012345604', '0012345603', 10000, 'kemi.payroll') IS NOT NULL AS posted;
RELEASE SAVEPOINT pay_chiamaka;
COMMIT;
SELECT account_number, balance FROM customer_account_balance WHERE account_number IN ('0012345601', '0012345603', '0012345604', '0012345605') ORDER BY 1;
