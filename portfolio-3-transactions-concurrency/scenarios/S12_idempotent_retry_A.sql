\echo 'A: Amina sends 2,500 to Tunde (key req-777); the response is slow, so the app times out'
BEGIN;
SELECT post_transfer('req-777', 'TRF-777', '0012345601', '0012345602', 2500, 'amina.mobile-app') AS transaction_id;
SELECT pg_sleep(1.5);
COMMIT;
