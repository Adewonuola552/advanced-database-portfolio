\pset footer off
SELECT account_number, balance FROM customer_account_balance ORDER BY account_number;
SELECT reference, transaction_type, status, amount, posted_at IS NOT NULL AS posted
  FROM financial_transaction
 WHERE reference NOT LIKE 'FIX-%'
 ORDER BY created_at;
