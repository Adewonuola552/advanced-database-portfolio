\echo 'A: withdraws 15,000 from Amina (balance 20,000) with the unlocked check-then-act code'
BEGIN;
SELECT unsafe_withdrawal('WDR-A', '0012345601', 15000, 2);
COMMIT;
