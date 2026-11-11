\echo 'B: transfers 1,000 Tunde -> Amina with post_transfer'
BEGIN;
SELECT post_transfer('req-B', 'TRF-B', '0012345602', '0012345601', 1000, 'demo') IS NOT NULL AS posted;
COMMIT;
