-- Tests that the schema accepts valid data and rejects invalid data.
-- Each attempt must fail with the named constraint or message. Any change it
-- makes is rolled back, so the tests leave the seed data untouched.

\set QUIET on
\pset format aligned
\pset footer off

CREATE TEMP TABLE test_result (
    test_no  SERIAL PRIMARY KEY,
    rule     TEXT NOT NULL,
    result   TEXT NOT NULL,
    database_message TEXT NOT NULL
);

CREATE PROCEDURE pg_temp.expect_reject(rule TEXT, expected TEXT, attempt TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    message TEXT;
BEGIN
    BEGIN
        EXECUTE attempt;
        -- Fire deferred checks now, as COMMIT would.
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'NOT REJECTED';
    EXCEPTION WHEN OTHERS THEN
        message := SQLERRM;
    END;
    INSERT INTO test_result (rule, result, database_message)
    VALUES (rule, CASE WHEN message LIKE '%' || expected || '%' THEN 'PASS' ELSE 'FAIL' END, message);
END;
$$;

\echo '=== Account balances after seed data (expected: 0012345601 = 15000.00, 0012345602 = 5000.00, 0012345603 = 0.00) ==='
SELECT account_number, currency_code, balance FROM customer_account_balance ORDER BY account_number;

\echo '=== Ledger entries for TX002 and its reversal REV001 ==='
SELECT ft.reference, ft.transaction_type, ft.status, a.account_number, le.line_number, le.entry_type, le.amount
  FROM ledger_entry le
  JOIN financial_transaction ft USING (transaction_id)
  JOIN account a USING (account_id)
 WHERE ft.reference IN ('TX002', 'REV001')
 ORDER BY ft.created_at, le.line_number;

BEGIN;

-- Domain constraints ---------------------------------------------------------
CALL pg_temp.expect_reject('Transaction amount must be above zero', 'ft_amount_check', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES ('T1', 'k1', 'DEPOSIT', 0, 'NGN') $q$);
CALL pg_temp.expect_reject('Currency must be NGN or USD', 'ft_currency_check', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES ('T2', 'k2', 'DEPOSIT', 10, 'EUR') $q$);
CALL pg_temp.expect_reject('Transaction type must be in the permitted list', 'ft_type_check', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES ('T3', 'k3', 'REFUND', 10, 'NGN') $q$);
CALL pg_temp.expect_reject('Account status must be in the permitted list', 'account_status_check', $q$
    UPDATE account SET status = 'DORMANT' WHERE account_number = '0012345601' $q$);
CALL pg_temp.expect_reject('Entry type must be DEBIT or CREDIT', 'le_type_check', $q$
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount)
    VALUES ('00000000-0000-0000-0000-000000000035', '00000000-0000-0000-0000-000000000021', 3, 'HOLD', 10) $q$);
CALL pg_temp.expect_reject('Line number must be above zero', 'le_line_number_check', $q$
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount)
    VALUES ('00000000-0000-0000-0000-000000000035', '00000000-0000-0000-0000-000000000021', 0, 'DEBIT', 10) $q$);
CALL pg_temp.expect_reject('Customer account must have an owner', 'account_owner_check', $q$
    INSERT INTO account (account_number, account_kind, currency_code) VALUES ('A1', 'CUSTOMER', 'NGN') $q$);
CALL pg_temp.expect_reject('Internal account must not have an owner', 'account_owner_check', $q$
    INSERT INTO account (customer_id, account_number, account_kind, currency_code)
    VALUES ('00000000-0000-0000-0000-000000000011', 'A2', 'INTERNAL', 'NGN') $q$);
CALL pg_temp.expect_reject('Reversal must reference an original', 'ft_reversal_link_check', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES ('T4', 'k4', 'REVERSAL', 10, 'NGN') $q$);
CALL pg_temp.expect_reject('Non-reversal must not reference an original', 'ft_reversal_link_check', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code, reversal_of_transaction_id)
    VALUES ('T5', 'k5', 'TRANSFER', 10, 'NGN', '00000000-0000-0000-0000-000000000032') $q$);
CALL pg_temp.expect_reject('Transaction cannot reverse itself', 'ft_not_self_reversal_check', $q$
    INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code, reversal_of_transaction_id)
    VALUES ('00000000-0000-0000-0000-000000000099', 'T6', 'k6', 'REVERSAL', 10, 'NGN', '00000000-0000-0000-0000-000000000099') $q$);
CALL pg_temp.expect_reject('Posted transaction needs posted_at', 'ft_posted_at_check', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code, status)
    VALUES ('T7', 'k7', 'DEPOSIT', 10, 'NGN', 'POSTED') $q$);
CALL pg_temp.expect_reject('Pending transaction must not have posted_at', 'ft_posted_at_check', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code, posted_at)
    VALUES ('T8', 'k8', 'DEPOSIT', 10, 'NGN', now()) $q$);

-- Keys -----------------------------------------------------------------------
CALL pg_temp.expect_reject('Customer email is unique', 'customer_email_unique', $q$
    INSERT INTO customer (first_name, last_name, email, phone)
    VALUES ('X', 'Y', 'amina.bello@example.com', '+2348000000009') $q$);
CALL pg_temp.expect_reject('Customer phone is unique', 'customer_phone_unique', $q$
    INSERT INTO customer (first_name, last_name, email, phone)
    VALUES ('X', 'Y', 'x.y@example.com', '+2348000000001') $q$);
CALL pg_temp.expect_reject('Account number is unique', 'account_number_unique', $q$
    INSERT INTO account (account_number, account_kind, currency_code) VALUES ('0012345601', 'INTERNAL', 'NGN') $q$);
CALL pg_temp.expect_reject('Transaction reference is unique', 'ft_reference_unique', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES ('TX001', 'k9', 'DEPOSIT', 10, 'NGN') $q$);
CALL pg_temp.expect_reject('Retried idempotency key cannot create a second transaction', 'ft_idempotency_unique', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES ('T9', 'idem-tx-001', 'TRANSFER', 5000, 'NGN') $q$);
CALL pg_temp.expect_reject('An original can only be fully reversed once', 'ft_reversal_unique', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code, reversal_of_transaction_id)
    VALUES ('T10', 'k10', 'REVERSAL', 2000, 'NGN', '00000000-0000-0000-0000-000000000033') $q$);
CALL pg_temp.expect_reject('Line number is unique within a transaction', 'le_line_unique', $q$
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount)
    VALUES ('00000000-0000-0000-0000-000000000035', '00000000-0000-0000-0000-000000000021', 1, 'DEBIT', 10) $q$);
CALL pg_temp.expect_reject('Entry must reference an existing account', 'le_account_fk', $q$
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount)
    VALUES ('00000000-0000-0000-0000-000000000035', '00000000-0000-0000-0000-0000000000ff', 3, 'DEBIT', 10) $q$);
CALL pg_temp.expect_reject('Customer with accounts cannot be deleted', 'account_customer_fk', $q$
    DELETE FROM customer WHERE customer_id = '00000000-0000-0000-0000-000000000011' $q$);
CALL pg_temp.expect_reject('Account with ledger history cannot be deleted', 'le_account_fk', $q$
    DELETE FROM account WHERE account_id = '00000000-0000-0000-0000-000000000021' $q$);

-- Financial integrity rules --------------------------------------------------
CALL pg_temp.expect_reject('Posted transaction needs at least two entries', 'at least two ledger entries', $q$
    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code, status, posted_at)
    VALUES ('T11', 'k11', 'DEPOSIT', 10, 'NGN', 'POSTED', now()) $q$);
CALL pg_temp.expect_reject('Posted debits must equal posted credits', 'is unbalanced', $q$
    INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES ('00000000-0000-0000-0000-000000000041', 'T12', 'k12', 'TRANSFER', 100, 'NGN');
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
        ('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000021', 1, 'DEBIT', 100),
        ('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000022', 2, 'CREDIT', 90);
    UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
     WHERE transaction_id = '00000000-0000-0000-0000-000000000041' $q$);
CALL pg_temp.expect_reject('Ledger total must match transaction amount', 'does not match transaction amount', $q$
    INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES ('00000000-0000-0000-0000-000000000042', 'T13', 'k13', 'TRANSFER', 100, 'NGN');
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
        ('00000000-0000-0000-0000-000000000042', '00000000-0000-0000-0000-000000000021', 1, 'DEBIT', 90),
        ('00000000-0000-0000-0000-000000000042', '00000000-0000-0000-0000-000000000022', 2, 'CREDIT', 90);
    UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
     WHERE transaction_id = '00000000-0000-0000-0000-000000000042' $q$);
CALL pg_temp.expect_reject('Affected accounts must use the transaction currency', 'currency mismatch', $q$
    INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES ('00000000-0000-0000-0000-000000000043', 'T14', 'k14', 'TRANSFER', 100, 'NGN');
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
        ('00000000-0000-0000-0000-000000000043', '00000000-0000-0000-0000-000000000021', 1, 'DEBIT', 100),
        ('00000000-0000-0000-0000-000000000043', '00000000-0000-0000-0000-000000000024', 2, 'CREDIT', 100);
    UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
     WHERE transaction_id = '00000000-0000-0000-0000-000000000043' $q$);
CALL pg_temp.expect_reject('Transfer must use different accounts', 'different source and destination', $q$
    INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES ('00000000-0000-0000-0000-000000000044', 'T15', 'k15', 'TRANSFER', 100, 'NGN');
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
        ('00000000-0000-0000-0000-000000000044', '00000000-0000-0000-0000-000000000021', 1, 'DEBIT', 100),
        ('00000000-0000-0000-0000-000000000044', '00000000-0000-0000-0000-000000000021', 2, 'CREDIT', 100);
    UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
     WHERE transaction_id = '00000000-0000-0000-0000-000000000044' $q$);
CALL pg_temp.expect_reject('Reversal must reference a posted original', 'must reference a posted transaction', $q$
    INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code, reversal_of_transaction_id)
    VALUES ('00000000-0000-0000-0000-000000000045', 'T16', 'k16', 'REVERSAL', 1000, 'NGN', '00000000-0000-0000-0000-000000000035');
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
        ('00000000-0000-0000-0000-000000000045', '00000000-0000-0000-0000-000000000022', 1, 'DEBIT', 1000),
        ('00000000-0000-0000-0000-000000000045', '00000000-0000-0000-0000-000000000021', 2, 'CREDIT', 1000);
    UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
     WHERE transaction_id = '00000000-0000-0000-0000-000000000045' $q$);
CALL pg_temp.expect_reject('Reversal must match the original amount', 'must match the original amount', $q$
    INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code, reversal_of_transaction_id)
    VALUES ('00000000-0000-0000-0000-000000000046', 'T17', 'k17', 'REVERSAL', 100, 'NGN', '00000000-0000-0000-0000-000000000032');
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
        ('00000000-0000-0000-0000-000000000046', '00000000-0000-0000-0000-000000000022', 1, 'DEBIT', 100),
        ('00000000-0000-0000-0000-000000000046', '00000000-0000-0000-0000-000000000021', 2, 'CREDIT', 100);
    UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
     WHERE transaction_id = '00000000-0000-0000-0000-000000000046' $q$);
CALL pg_temp.expect_reject('Reversal must invert the original entries', 'does not invert', $q$
    INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code, reversal_of_transaction_id)
    VALUES ('00000000-0000-0000-0000-000000000047', 'T18', 'k18', 'REVERSAL', 5000, 'NGN', '00000000-0000-0000-0000-000000000032');
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
        ('00000000-0000-0000-0000-000000000047', '00000000-0000-0000-0000-000000000021', 1, 'DEBIT', 5000),
        ('00000000-0000-0000-0000-000000000047', '00000000-0000-0000-0000-000000000022', 2, 'CREDIT', 5000);
    UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
     WHERE transaction_id = '00000000-0000-0000-0000-000000000047' $q$);
CALL pg_temp.expect_reject('Posted ledger entry cannot be updated', 'posted ledger entries are immutable', $q$
    UPDATE ledger_entry SET amount = 1 WHERE transaction_id = '00000000-0000-0000-0000-000000000032' $q$);
CALL pg_temp.expect_reject('Posted ledger entry cannot be deleted', 'posted ledger entries are immutable', $q$
    DELETE FROM ledger_entry WHERE transaction_id = '00000000-0000-0000-0000-000000000032' $q$);
CALL pg_temp.expect_reject('Entry cannot be added to a posted transaction', 'cannot add ledger entries', $q$
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount)
    VALUES ('00000000-0000-0000-0000-000000000032', '00000000-0000-0000-0000-000000000021', 3, 'DEBIT', 10) $q$);
CALL pg_temp.expect_reject('Posted transaction cannot be changed', 'only pending transactions', $q$
    UPDATE financial_transaction SET amount = 1 WHERE transaction_id = '00000000-0000-0000-0000-000000000032' $q$);
CALL pg_temp.expect_reject('Posted transaction cannot be deleted', 'posted transactions cannot be deleted', $q$
    DELETE FROM financial_transaction WHERE transaction_id = '00000000-0000-0000-0000-000000000032' $q$);

COMMIT;

\pset format aligned
\echo '=== Rejection tests ==='
SELECT test_no, result, rule, left(database_message, 70) AS database_message FROM test_result ORDER BY test_no;

\echo '=== Summary ==='
SELECT count(*) AS total,
       count(*) FILTER (WHERE result = 'PASS') AS passed,
       count(*) FILTER (WHERE result <> 'PASS') AS failed
  FROM test_result;

\echo '=== Real COMMIT of an unbalanced transfer: COMMIT itself must report an error ==='
BEGIN;
INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code)
VALUES ('00000000-0000-0000-0000-000000000051', 'T19', 'k19', 'TRANSFER', 100, 'NGN');
INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
    ('00000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000021', 1, 'DEBIT', 100),
    ('00000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000022', 2, 'CREDIT', 90);
UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
 WHERE transaction_id = '00000000-0000-0000-0000-000000000051';
COMMIT;

\echo '=== Rows left by the failed COMMIT (expected: 0) ==='
SELECT count(*) AS rows_left FROM financial_transaction WHERE reference = 'T19';

\echo '=== Balances after all tests (expected: unchanged) ==='
SELECT account_number, currency_code, balance FROM customer_account_balance ORDER BY account_number;
