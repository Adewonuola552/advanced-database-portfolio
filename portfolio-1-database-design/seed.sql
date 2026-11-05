-- ClearPay sample data. All people and accounts are simulated.
-- Fixed UUIDs keep the tests readable: 1x = customers, 2x = accounts, 3x = transactions.

\set ON_ERROR_STOP on

BEGIN;

INSERT INTO customer (customer_id, first_name, last_name, email, phone) VALUES
    ('00000000-0000-0000-0000-000000000011', 'Amina', 'Bello',  'amina.bello@example.com',  '+2348000000001'),
    ('00000000-0000-0000-0000-000000000012', 'Tunde', 'Okoro',  'tunde.okoro@example.com',  '+2348000000002');

INSERT INTO account (account_id, customer_id, account_number, account_kind, currency_code) VALUES
    ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000011', '0012345601', 'CUSTOMER', 'NGN'),
    ('00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000012', '0012345602', 'CUSTOMER', 'NGN'),
    ('00000000-0000-0000-0000-000000000023', NULL,                                   'INT-NGN-01', 'INTERNAL', 'NGN'),
    ('00000000-0000-0000-0000-000000000024', '00000000-0000-0000-0000-000000000012', '0012345603', 'CUSTOMER', 'USD');

COMMIT;

-- Deposit: credit the customer account, debit internal settlement.
BEGIN;
INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code)
VALUES ('00000000-0000-0000-0000-000000000031', 'DEP001', 'idem-dep-001', 'DEPOSIT', 20000.00, 'NGN');
INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
    ('00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000023', 1, 'DEBIT',  20000.00),
    ('00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000021', 2, 'CREDIT', 20000.00);
UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
 WHERE transaction_id = '00000000-0000-0000-0000-000000000031';
COMMIT;

-- Transfer TX001: Amina to Tunde, NGN 5,000.
BEGIN;
INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code)
VALUES ('00000000-0000-0000-0000-000000000032', 'TX001', 'idem-tx-001', 'TRANSFER', 5000.00, 'NGN');
INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
    ('00000000-0000-0000-0000-000000000032', '00000000-0000-0000-0000-000000000021', 1, 'DEBIT',  5000.00),
    ('00000000-0000-0000-0000-000000000032', '00000000-0000-0000-0000-000000000022', 2, 'CREDIT', 5000.00);
UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
 WHERE transaction_id = '00000000-0000-0000-0000-000000000032';
COMMIT;

-- Transfer TX002: NGN 2,000, later fully reversed by REV001.
BEGIN;
INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code)
VALUES ('00000000-0000-0000-0000-000000000033', 'TX002', 'idem-tx-002', 'TRANSFER', 2000.00, 'NGN');
INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
    ('00000000-0000-0000-0000-000000000033', '00000000-0000-0000-0000-000000000021', 1, 'DEBIT',  2000.00),
    ('00000000-0000-0000-0000-000000000033', '00000000-0000-0000-0000-000000000022', 2, 'CREDIT', 2000.00);
UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
 WHERE transaction_id = '00000000-0000-0000-0000-000000000033';
COMMIT;

BEGIN;
INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code, reversal_of_transaction_id)
VALUES ('00000000-0000-0000-0000-000000000034', 'REV001', 'idem-rev-001', 'REVERSAL', 2000.00, 'NGN', '00000000-0000-0000-0000-000000000033');
INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
    ('00000000-0000-0000-0000-000000000034', '00000000-0000-0000-0000-000000000022', 1, 'DEBIT',  2000.00),
    ('00000000-0000-0000-0000-000000000034', '00000000-0000-0000-0000-000000000021', 2, 'CREDIT', 2000.00);
UPDATE financial_transaction SET status = 'POSTED', posted_at = now()
 WHERE transaction_id = '00000000-0000-0000-0000-000000000034';
INSERT INTO audit_log (transaction_id, actor_identifier, action, details)
VALUES ('00000000-0000-0000-0000-000000000034', 'finance.officer01', 'REVERSAL_AUTHORISED', '{"reason": "customer dispute"}');
COMMIT;

-- Pending TX003: has entries but must not affect any balance.
BEGIN;
INSERT INTO financial_transaction (transaction_id, reference, idempotency_key, transaction_type, amount, currency_code)
VALUES ('00000000-0000-0000-0000-000000000035', 'TX003', 'idem-tx-003', 'TRANSFER', 1000.00, 'NGN');
INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
    ('00000000-0000-0000-0000-000000000035', '00000000-0000-0000-0000-000000000021', 1, 'DEBIT',  1000.00),
    ('00000000-0000-0000-0000-000000000035', '00000000-0000-0000-0000-000000000022', 2, 'CREDIT', 1000.00);
COMMIT;

-- General system event with no transaction.
INSERT INTO audit_log (actor_identifier, action, details)
VALUES ('sysadmin01', 'SCHEDULED_BACKUP_COMPLETED', '{"target": "clearpay"}');
