-- Starting data for every Portfolio 3 scenario. All people and accounts are simulated.
-- The runner rebuilds the database before each scenario, so every scenario starts here.
--
--   0012345601  Amina Bello      NGN  20,000.00
--   0012345602  Tunde Okoro      NGN   5,000.00
--   0012345603  Chiamaka Eze     NGN       0.00
--   0012345604  Kemi Adeyemi     NGN 100,000.00  (business account, runs payroll in S02)
--   0012345605  Musa Ibrahim     NGN       0.00  FROZEN
--   INT-NGN-01  internal settlement account

\set ON_ERROR_STOP on

BEGIN;

INSERT INTO customer (first_name, last_name, email, phone) VALUES
    ('Amina',    'Bello',   'amina.bello@example.com',   '+2348000000001'),
    ('Tunde',    'Okoro',   'tunde.okoro@example.com',   '+2348000000002'),
    ('Chiamaka', 'Eze',     'chiamaka.eze@example.com',  '+2348000000003'),
    ('Kemi',     'Adeyemi', 'kemi.adeyemi@example.com',  '+2348000000004'),
    ('Musa',     'Ibrahim', 'musa.ibrahim@example.com',  '+2348000000005');

INSERT INTO account (customer_id, account_number, account_kind, currency_code)
SELECT customer_id, num, 'CUSTOMER', 'NGN'
  FROM (VALUES ('amina.bello@example.com',  '0012345601'),
               ('tunde.okoro@example.com',  '0012345602'),
               ('chiamaka.eze@example.com', '0012345603'),
               ('kemi.adeyemi@example.com', '0012345604'),
               ('musa.ibrahim@example.com', '0012345605')) AS v(email, num)
  JOIN customer USING (email);

INSERT INTO account (account_number, account_kind, currency_code)
VALUES ('INT-NGN-01', 'INTERNAL', 'NGN');

COMMIT;

SELECT post_deposit('fix-dep-1', 'FIX-DEP-1', '0012345601', 20000, 'fixture');
SELECT post_deposit('fix-dep-2', 'FIX-DEP-2', '0012345602', 5000, 'fixture');
SELECT post_deposit('fix-dep-4', 'FIX-DEP-4', '0012345604', 100000, 'fixture');

UPDATE account SET status = 'FROZEN' WHERE account_number = '0012345605';
