\echo 'B: withdraws 15,000 from Amina (balance 20,000) with the unlocked check-then-act code'
BEGIN;
SELECT unsafe_withdrawal('WDR-B', '0012345601', 15000, 2);
COMMIT;
