-- ClearPay posting procedures (Portfolio 3). Run after portfolio-1-database-design/schema.sql.
--
-- Portfolio 1 left three rules to "the posting procedure": sufficient funds, account
-- eligibility, and rejecting a reused idempotency key with different details. They are
-- implemented here, together with the concurrency control that makes them safe when
-- several requests for the same account arrive at once.
--
-- Concurrency control: every posting locks its accounts with SELECT ... FOR UPDATE, in
-- account_id order, before it reads a balance. A second posting on the same account waits
-- for the first to commit, and then reads a balance that includes it. The fixed lock order
-- means two opposite transfers (A to B and B to A) cannot deadlock.

\set ON_ERROR_STOP on

BEGIN;

-- Balance of one account, from posted ledger entries only (the same rule as the
-- customer_account_balance view in Portfolio 1).
CREATE FUNCTION account_balance(p_account_id UUID) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT coalesce(sum(CASE WHEN le.entry_type = 'CREDIT' THEN le.amount ELSE -le.amount END), 0)
      FROM ledger_entry le
      JOIN financial_transaction ft USING (transaction_id)
     WHERE le.account_id = p_account_id
       AND ft.status = 'POSTED';
$$;

-- Core posting routine: one debit leg and one credit leg. The public functions below
-- choose the accounts for each transaction type and call this.
CREATE FUNCTION post_two_leg(
    p_type            VARCHAR,
    p_idempotency_key VARCHAR,
    p_reference       VARCHAR,
    p_debit_account   VARCHAR,
    p_credit_account  VARCHAR,
    p_amount          NUMERIC,
    p_actor           VARCHAR,
    p_reversal_of     UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE
    v_debit    account%ROWTYPE;
    v_credit   account%ROWTYPE;
    v_existing financial_transaction%ROWTYPE;
    v_balance  NUMERIC;
    v_tx       UUID;
BEGIN
    -- A REPEATABLE READ snapshot is fixed at the first statement, so after waiting for
    -- the lock it would still read the balance from before the other posting, and could
    -- overdraw the account. Scenario S09 shows this, using the demo-only setting
    -- clearpay.unsafe_allow_repeatable_read to switch the guard off. READ COMMITTED takes
    -- a new snapshot for each statement; SERIALIZABLE detects the conflict and aborts one.
    IF current_setting('transaction_isolation') = 'repeatable read'
       AND coalesce(current_setting('clearpay.unsafe_allow_repeatable_read', true), '') <> 'on' THEN
        RAISE EXCEPTION 'postings must run under READ COMMITTED or SERIALIZABLE, not REPEATABLE READ';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'amount must be above zero';
    END IF;

    -- 1. Lock both accounts in a fixed order (pessimistic concurrency control).
    PERFORM 1
       FROM account
      WHERE account_number IN (p_debit_account, p_credit_account)
      ORDER BY account_id
        FOR UPDATE;

    -- These reads start after the locks are held, so under READ COMMITTED they see
    -- every posting that committed while this session was waiting.
    SELECT * INTO v_debit FROM account WHERE account_number = p_debit_account;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown account %', p_debit_account;
    END IF;
    SELECT * INTO v_credit FROM account WHERE account_number = p_credit_account;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown account %', p_credit_account;
    END IF;
    IF v_debit.account_id = v_credit.account_id THEN
        RAISE EXCEPTION 'source and destination accounts must differ';
    END IF;

    -- 2. Idempotency: a retry with the same key and the same details returns the original
    --    transaction; the same key with different details is rejected.
    SELECT * INTO v_existing FROM financial_transaction WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_existing.transaction_type = p_type
           AND v_existing.amount = p_amount
           AND v_existing.currency_code = v_debit.currency_code
           AND EXISTS (SELECT 1 FROM ledger_entry
                        WHERE transaction_id = v_existing.transaction_id
                          AND account_id = v_debit.account_id AND entry_type = 'DEBIT')
           AND EXISTS (SELECT 1 FROM ledger_entry
                        WHERE transaction_id = v_existing.transaction_id
                          AND account_id = v_credit.account_id AND entry_type = 'CREDIT')
        THEN
            RAISE NOTICE 'idempotency key % was already processed as %: returning the original transaction',
                p_idempotency_key, v_existing.reference;
            RETURN v_existing.transaction_id;
        END IF;
        RAISE EXCEPTION 'idempotency key % was already used for a different request (%)',
            p_idempotency_key, v_existing.reference;
    END IF;

    -- 3. Account eligibility: customer accounts must be ACTIVE; one currency per transaction.
    IF v_debit.account_kind = 'CUSTOMER' AND v_debit.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'account % is %', v_debit.account_number, v_debit.status;
    END IF;
    IF v_credit.account_kind = 'CUSTOMER' AND v_credit.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'account % is %', v_credit.account_number, v_credit.status;
    END IF;
    IF v_debit.currency_code <> v_credit.currency_code THEN
        RAISE EXCEPTION 'currency mismatch: % is %, % is %',
            v_debit.account_number, v_debit.currency_code, v_credit.account_number, v_credit.currency_code;
    END IF;

    -- 4. Sufficient funds. Internal settlement accounts may go negative.
    IF v_debit.account_kind = 'CUSTOMER' THEN
        v_balance := account_balance(v_debit.account_id);
        IF v_balance < p_amount THEN
            RAISE EXCEPTION 'insufficient funds in %: balance %, requested %',
                v_debit.account_number, v_balance, p_amount;
        END IF;
    END IF;

    -- 5. Write the transaction and both legs, then post. The Portfolio 1 deferred
    --    trigger checks the balanced entries at COMMIT.
    INSERT INTO financial_transaction
        (reference, idempotency_key, transaction_type, amount, currency_code, reversal_of_transaction_id)
    VALUES (p_reference, p_idempotency_key, p_type, p_amount, v_debit.currency_code, p_reversal_of)
    RETURNING transaction_id INTO v_tx;

    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
        (v_tx, v_debit.account_id,  1, 'DEBIT',  p_amount),
        (v_tx, v_credit.account_id, 2, 'CREDIT', p_amount);

    UPDATE financial_transaction SET status = 'POSTED', posted_at = now() WHERE transaction_id = v_tx;

    INSERT INTO audit_log (transaction_id, actor_identifier, action, details)
    VALUES (v_tx, p_actor, p_type || '_POSTED',
            jsonb_build_object('reference', p_reference,
                               'debit_account', p_debit_account,
                               'credit_account', p_credit_account,
                               'amount', p_amount,
                               'isolation', current_setting('transaction_isolation')));
    RETURN v_tx;
END;
$$;

CREATE FUNCTION post_deposit(p_idempotency_key VARCHAR, p_reference VARCHAR,
                             p_account VARCHAR, p_amount NUMERIC, p_actor VARCHAR DEFAULT 'api')
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE
    v_currency CHAR(3);
BEGIN
    SELECT currency_code INTO v_currency FROM account
     WHERE account_number = p_account AND account_kind = 'CUSTOMER';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown customer account %', p_account;
    END IF;
    -- Debit the internal settlement account, credit the customer.
    RETURN post_two_leg('DEPOSIT', p_idempotency_key, p_reference,
                        'INT-' || v_currency || '-01', p_account, p_amount, p_actor);
END;
$$;

CREATE FUNCTION post_withdrawal(p_idempotency_key VARCHAR, p_reference VARCHAR,
                                p_account VARCHAR, p_amount NUMERIC, p_actor VARCHAR DEFAULT 'api')
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE
    v_currency CHAR(3);
BEGIN
    SELECT currency_code INTO v_currency FROM account
     WHERE account_number = p_account AND account_kind = 'CUSTOMER';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown customer account %', p_account;
    END IF;
    RETURN post_two_leg('WITHDRAWAL', p_idempotency_key, p_reference,
                        p_account, 'INT-' || v_currency || '-01', p_amount, p_actor);
END;
$$;

CREATE FUNCTION post_transfer(p_idempotency_key VARCHAR, p_reference VARCHAR,
                              p_from_account VARCHAR, p_to_account VARCHAR,
                              p_amount NUMERIC, p_actor VARCHAR DEFAULT 'api')
RETURNS UUID LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM account
                WHERE account_number IN (p_from_account, p_to_account)
                  AND account_kind <> 'CUSTOMER') THEN
        RAISE EXCEPTION 'transfers are between customer accounts only';
    END IF;
    RETURN post_two_leg('TRANSFER', p_idempotency_key, p_reference,
                        p_from_account, p_to_account, p_amount, p_actor);
END;
$$;

-- Full reversal: a new REVERSAL transaction with the legs swapped. The original stays.
CREATE FUNCTION reverse_transaction(p_original_reference VARCHAR, p_idempotency_key VARCHAR,
                                    p_actor VARCHAR)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE
    v_original financial_transaction%ROWTYPE;
    v_debit    VARCHAR;
    v_credit   VARCHAR;
BEGIN
    SELECT * INTO v_original FROM financial_transaction WHERE reference = p_original_reference;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown transaction %', p_original_reference;
    END IF;
    IF v_original.status <> 'POSTED' OR v_original.transaction_type = 'REVERSAL' THEN
        RAISE EXCEPTION 'only posted, non-reversal transactions can be reversed';
    END IF;
    SELECT a.account_number INTO v_debit FROM ledger_entry le JOIN account a USING (account_id)
     WHERE le.transaction_id = v_original.transaction_id AND le.entry_type = 'DEBIT';
    SELECT a.account_number INTO v_credit FROM ledger_entry le JOIN account a USING (account_id)
     WHERE le.transaction_id = v_original.transaction_id AND le.entry_type = 'CREDIT';
    -- The ft_reversal_unique constraint also stops a second reversal, including one
    -- submitted concurrently with a different idempotency key.
    RETURN post_two_leg('REVERSAL', p_idempotency_key, 'REV-' || p_original_reference,
                        v_credit, v_debit, v_original.amount, p_actor, v_original.transaction_id);
END;
$$;

COMMIT;
