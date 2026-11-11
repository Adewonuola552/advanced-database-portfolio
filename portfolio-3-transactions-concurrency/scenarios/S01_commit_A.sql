\echo '--- Balances before'
SELECT account_number, balance FROM customer_account_balance WHERE account_number IN ('0012345601', '0012345602') ORDER BY 1;
\echo '--- Amina transfers 5,000 to Tunde. The procedure writes the transaction, two ledger legs and an audit record.'
BEGIN;
SELECT post_transfer('req-1001', 'TRF-1001', '0012345601', '0012345602', 5000, 'amina.mobile-app') IS NOT NULL AS posted;
COMMIT;
\echo '--- Balances after COMMIT'
SELECT account_number, balance FROM customer_account_balance WHERE account_number IN ('0012345601', '0012345602') ORDER BY 1;
\echo '--- What the COMMIT made permanent'
SELECT ft.reference, ft.transaction_type, ft.status, le.line_number, a.account_number, le.entry_type, le.amount
  FROM financial_transaction ft JOIN ledger_entry le USING (transaction_id) JOIN account a USING (account_id)
 WHERE ft.reference = 'TRF-1001' ORDER BY le.line_number;
SELECT actor_identifier, action, details FROM audit_log WHERE details->>'reference' = 'TRF-1001';
\echo '--- A finance officer reverses the transfer. The reversal is a new transaction; the original is kept.'
BEGIN;
SELECT reverse_transaction('TRF-1001', 'req-rev-1001', 'finance.officer1') IS NOT NULL AS posted;
COMMIT;
SELECT ft.reference, ft.transaction_type, le.line_number, a.account_number, le.entry_type, le.amount
  FROM financial_transaction ft JOIN ledger_entry le USING (transaction_id) JOIN account a USING (account_id)
 WHERE ft.reference IN ('TRF-1001', 'REV-TRF-1001') ORDER BY ft.created_at, le.line_number;
SELECT account_number, balance FROM customer_account_balance WHERE account_number IN ('0012345601', '0012345602') ORDER BY 1;
