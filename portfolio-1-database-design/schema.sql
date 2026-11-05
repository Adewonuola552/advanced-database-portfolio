-- ClearPay Digital Fintech Platform: relational schema (PostgreSQL 13+)
-- MIT 8103 Portfolio 1

BEGIN;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE customer (
    customer_id UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name  VARCHAR(100) NOT NULL,
    last_name   VARCHAR(100) NOT NULL,
    email       VARCHAR(255) NOT NULL,
    phone       VARCHAR(20)  NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT customer_email_unique UNIQUE (email),
    CONSTRAINT customer_phone_unique UNIQUE (phone)
);

CREATE TABLE account (
    account_id     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id    UUID,       -- NULL only for internal settlement accounts
    account_number VARCHAR(20) NOT NULL,  -- text keeps leading zeroes
    account_kind   VARCHAR(20) NOT NULL,
    currency_code  CHAR(3)     NOT NULL,
    status         VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT account_number_unique UNIQUE (account_number),
    CONSTRAINT account_customer_fk FOREIGN KEY (customer_id)
        REFERENCES customer (customer_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT account_kind_check CHECK (account_kind IN ('CUSTOMER', 'INTERNAL')),
    CONSTRAINT account_status_check CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    CONSTRAINT account_currency_check CHECK (currency_code IN ('NGN', 'USD')),
    CONSTRAINT account_owner_check CHECK (
        (account_kind = 'CUSTOMER' AND customer_id IS NOT NULL)
        OR (account_kind = 'INTERNAL' AND customer_id IS NULL)
    )
);

CREATE TABLE financial_transaction (
    transaction_id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    reference                 VARCHAR(50)   NOT NULL,
    idempotency_key           VARCHAR(100)  NOT NULL,
    transaction_type          VARCHAR(20)   NOT NULL,
    amount                    NUMERIC(18,2) NOT NULL,
    currency_code             CHAR(3)       NOT NULL,
    status                    VARCHAR(20)   NOT NULL DEFAULT 'PENDING',
    reversal_of_transaction_id UUID,
    created_at                TIMESTAMPTZ   NOT NULL DEFAULT now(),
    posted_at                 TIMESTAMPTZ,
    CONSTRAINT ft_reference_unique UNIQUE (reference),
    CONSTRAINT ft_idempotency_unique UNIQUE (idempotency_key),
    CONSTRAINT ft_reversal_unique UNIQUE (reversal_of_transaction_id),  -- one full reversal per original
    CONSTRAINT ft_reversal_fk FOREIGN KEY (reversal_of_transaction_id)
        REFERENCES financial_transaction (transaction_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT ft_type_check CHECK (transaction_type IN ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER', 'REVERSAL')),
    CONSTRAINT ft_status_check CHECK (status IN ('PENDING', 'POSTED', 'FAILED')),
    CONSTRAINT ft_amount_check CHECK (amount > 0),
    CONSTRAINT ft_currency_check CHECK (currency_code IN ('NGN', 'USD')),
    CONSTRAINT ft_reversal_link_check CHECK (
        (transaction_type = 'REVERSAL' AND reversal_of_transaction_id IS NOT NULL)
        OR (transaction_type <> 'REVERSAL' AND reversal_of_transaction_id IS NULL)
    ),
    CONSTRAINT ft_not_self_reversal_check CHECK (
        reversal_of_transaction_id IS NULL OR reversal_of_transaction_id <> transaction_id
    ),
    CONSTRAINT ft_posted_at_check CHECK (
        (status = 'POSTED' AND posted_at IS NOT NULL)
        OR (status IN ('PENDING', 'FAILED') AND posted_at IS NULL)
    )
);

CREATE TABLE ledger_entry (
    entry_id       UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID          NOT NULL,
    account_id     UUID          NOT NULL,
    line_number    SMALLINT      NOT NULL,
    entry_type     VARCHAR(6)    NOT NULL,
    amount         NUMERIC(18,2) NOT NULL,
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT le_line_unique UNIQUE (transaction_id, line_number),
    CONSTRAINT le_transaction_fk FOREIGN KEY (transaction_id)
        REFERENCES financial_transaction (transaction_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT le_account_fk FOREIGN KEY (account_id)
        REFERENCES account (account_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT le_type_check CHECK (entry_type IN ('DEBIT', 'CREDIT')),
    CONSTRAINT le_amount_check CHECK (amount > 0),
    CONSTRAINT le_line_number_check CHECK (line_number > 0)
);

CREATE TABLE audit_log (
    audit_id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id   UUID,        -- NULL for general system events
    actor_identifier VARCHAR(100) NOT NULL,
    action           VARCHAR(100) NOT NULL,
    details          JSONB        NOT NULL DEFAULT '{}',
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT audit_transaction_fk FOREIGN KEY (transaction_id)
        REFERENCES financial_transaction (transaction_id) ON UPDATE RESTRICT ON DELETE RESTRICT
);

-- ---------------------------------------------------------------------------
-- Multi-row rules: a CHECK constraint can only see one row, so these use triggers
-- ---------------------------------------------------------------------------

-- Posted ledger entries cannot be added to, changed or deleted.
-- FOR SHARE conflicts with the UPDATE that posts a transaction, so an entry
-- cannot slip in while another session is posting the same transaction.
CREATE FUNCTION ledger_entry_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    parent_status VARCHAR(20);
BEGIN
    IF TG_OP <> 'INSERT' THEN
        SELECT status INTO parent_status FROM financial_transaction
         WHERE transaction_id = OLD.transaction_id FOR SHARE;
        IF parent_status = 'POSTED' THEN
            RAISE EXCEPTION 'posted ledger entries are immutable';
        END IF;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        SELECT status INTO parent_status FROM financial_transaction
         WHERE transaction_id = NEW.transaction_id FOR SHARE;
        IF parent_status = 'POSTED' THEN
            RAISE EXCEPTION 'cannot add ledger entries to a posted transaction';
        END IF;
        RETURN NEW;
    END IF;
    RETURN OLD;
END;
$$;

CREATE TRIGGER ledger_entry_guard_trg
    BEFORE INSERT OR UPDATE OR DELETE ON ledger_entry
    FOR EACH ROW EXECUTE FUNCTION ledger_entry_guard();

-- Only PENDING transactions may change. POSTED and FAILED are final, and a
-- correction is a new linked REVERSAL, which preserves the original history.
CREATE FUNCTION financial_transaction_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status = 'POSTED' THEN
            RAISE EXCEPTION 'posted transactions cannot be deleted';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.status <> 'PENDING' THEN
        RAISE EXCEPTION 'only pending transactions can be changed';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER financial_transaction_guard_trg
    BEFORE UPDATE OR DELETE ON financial_transaction
    FOR EACH ROW EXECUTE FUNCTION financial_transaction_guard();

-- Validates a posted transaction as a whole. It runs at COMMIT (deferred), so
-- the transaction and its entries can be written in any order beforehand.
CREATE FUNCTION validate_posted_transaction() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    entry_count    INTEGER;
    total_debits   NUMERIC;
    total_credits  NUMERIC;
    original_tx    financial_transaction%ROWTYPE;
BEGIN
    SELECT count(*),
           coalesce(sum(amount) FILTER (WHERE entry_type = 'DEBIT'), 0),
           coalesce(sum(amount) FILTER (WHERE entry_type = 'CREDIT'), 0)
      INTO entry_count, total_debits, total_credits
      FROM ledger_entry
     WHERE transaction_id = NEW.transaction_id;

    IF entry_count < 2 THEN
        RAISE EXCEPTION 'posted transaction % needs at least two ledger entries', NEW.reference;
    END IF;
    IF total_debits <> total_credits THEN
        RAISE EXCEPTION 'posted transaction % is unbalanced: debits %, credits %',
            NEW.reference, total_debits, total_credits;
    END IF;
    IF total_debits <> NEW.amount THEN
        RAISE EXCEPTION 'ledger total % does not match transaction amount % for %',
            total_debits, NEW.amount, NEW.reference;
    END IF;

    IF EXISTS (SELECT 1 FROM ledger_entry le JOIN account a USING (account_id)
                WHERE le.transaction_id = NEW.transaction_id
                  AND a.currency_code <> NEW.currency_code) THEN
        RAISE EXCEPTION 'currency mismatch between transaction % and an account', NEW.reference;
    END IF;

    IF NEW.transaction_type = 'TRANSFER'
       AND (SELECT count(DISTINCT account_id) FROM ledger_entry
             WHERE transaction_id = NEW.transaction_id) < 2 THEN
        RAISE EXCEPTION 'transfer % must use different source and destination accounts', NEW.reference;
    END IF;

    IF NEW.transaction_type = 'REVERSAL' THEN
        SELECT * INTO original_tx FROM financial_transaction
         WHERE transaction_id = NEW.reversal_of_transaction_id;
        IF original_tx.status <> 'POSTED' THEN
            RAISE EXCEPTION 'reversal % must reference a posted transaction', NEW.reference;
        END IF;
        IF original_tx.amount <> NEW.amount OR original_tx.currency_code <> NEW.currency_code THEN
            RAISE EXCEPTION 'reversal % must match the original amount and currency', NEW.reference;
        END IF;
        -- Inverted entries: each account's net effect across both transactions is zero.
        IF EXISTS (
            SELECT 1
              FROM ledger_entry
             WHERE transaction_id IN (NEW.transaction_id, NEW.reversal_of_transaction_id)
             GROUP BY account_id
            HAVING sum(CASE WHEN entry_type = 'CREDIT' THEN amount ELSE -amount END) <> 0
        ) THEN
            RAISE EXCEPTION 'reversal % does not invert the original entries', NEW.reference;
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER validate_posted_transaction_trg
    AFTER INSERT OR UPDATE ON financial_transaction
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (NEW.status = 'POSTED')
    EXECUTE FUNCTION validate_posted_transaction();

-- ---------------------------------------------------------------------------
-- Balances are derived from posted entries, so no stored balance can disagree
-- with the ledger. Pending and failed transactions have no effect.
-- ---------------------------------------------------------------------------

CREATE VIEW customer_account_balance AS
SELECT a.account_id,
       a.account_number,
       a.currency_code,
       coalesce(sum(CASE WHEN le.entry_type = 'CREDIT' THEN le.amount ELSE -le.amount END)
                FILTER (WHERE ft.status = 'POSTED'), 0)::NUMERIC(18,2) AS balance
  FROM account a
  LEFT JOIN ledger_entry le ON le.account_id = a.account_id
  LEFT JOIN financial_transaction ft ON ft.transaction_id = le.transaction_id
 WHERE a.account_kind = 'CUSTOMER'
 GROUP BY a.account_id, a.account_number, a.currency_code;

COMMIT;
