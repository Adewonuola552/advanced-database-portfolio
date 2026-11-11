\echo 'A: transfers 1,000 Amina -> Tunde, locking Amina first, then Tunde'
BEGIN;
SELECT unordered_transfer('TRF-A', '0012345601', '0012345602', 1000, 1.5) IS NOT NULL AS posted;
COMMIT;
