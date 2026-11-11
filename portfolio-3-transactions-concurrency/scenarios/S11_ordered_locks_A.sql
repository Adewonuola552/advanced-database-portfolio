\echo 'A: transfers 1,000 Amina -> Tunde with post_transfer (locks in account_id order), holds for 1.5 seconds'
BEGIN;
SELECT post_transfer('req-A', 'TRF-A', '0012345601', '0012345602', 1000, 'demo') IS NOT NULL AS posted;
SELECT pg_sleep(1.5);
COMMIT;
