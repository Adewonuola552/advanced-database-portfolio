\echo 'B: transfers 1,000 Tunde -> Amina, locking Tunde first, then Amina'
BEGIN;
SELECT unordered_transfer('TRF-B', '0012345602', '0012345601', 1000, 1.5) IS NOT NULL AS posted;
COMMIT;
