\echo 'B (Amina''s app): transfers 5,000 to Tunde and commits while the report is running'
BEGIN;
SELECT post_transfer('req-3001', 'TRF-3001', '0012345601', '0012345602', 5000, 'amina.mobile-app') IS NOT NULL AS posted;
COMMIT;
