\echo 'A: the same unlocked code as S06, but under SERIALIZABLE'
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT unsafe_withdrawal('WDR-A', '0012345601', 15000, 2);
COMMIT;
