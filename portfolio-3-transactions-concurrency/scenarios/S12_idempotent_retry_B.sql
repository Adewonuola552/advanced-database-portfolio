\echo 'B: the app retries the same request with the same key while A is still running'
BEGIN;
SELECT post_transfer('req-777', 'TRF-777-RETRY', '0012345601', '0012345602', 2500, 'amina.mobile-app') AS transaction_id;
COMMIT;
\echo 'B: a buggy client reuses the key for a different amount'
BEGIN;
SELECT post_transfer('req-777', 'TRF-778', '0012345601', '0012345602', 9999, 'amina.mobile-app') AS transaction_id;
COMMIT;
SELECT reference, idempotency_key, amount FROM financial_transaction WHERE idempotency_key = 'req-777';
