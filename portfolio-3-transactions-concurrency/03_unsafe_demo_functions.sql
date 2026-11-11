-- DELIBERATELY UNSAFE functions, used only to reproduce concurrency problems.
-- ClearPay's real postings use 01_procedures.sql. Each function takes a "think time"
-- that stands in for the work an application does between reading and writing (fraud
-- checks, calling a partner bank). The pause widens the race window so that the problem
-- appears on every run instead of occasionally.

\set ON_ERROR_STOP on

BEGIN;

-- Check-then-act without a lock: read the balance, pause, then write if it looked high
-- enough. Two concurrent withdrawals can both pass the check (scenarios S06 and S08).
CREATE FUNCTION unsafe_withdrawal(p_reference VARCHAR, p_account VARCHAR,
                                  p_amount NUMERIC, p_think_seconds NUMERIC)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_account account%ROWTYPE;
    v_internal UUID;
    v_balance NUMERIC;
    v_tx UUID;
BEGIN
    SELECT * INTO v_account FROM account WHERE account_number = p_account;
    SELECT account_id INTO v_internal FROM account WHERE account_number = 'INT-NGN-01';

    v_balance := account_balance(v_account.account_id);
    RAISE NOTICE '% read balance % at %', p_reference, v_balance, to_char(clock_timestamp(), 'HH24:MI:SS.MS');

    PERFORM pg_sleep(p_think_seconds);

    IF v_balance < p_amount THEN
        RAISE EXCEPTION '% rejected: insufficient funds (balance %, requested %)', p_reference, v_balance, p_amount;
    END IF;

    INSERT INTO financial_transaction (reference, idempotency_key, transaction_type, amount, currency_code)
    VALUES (p_reference, 'idem-' || p_reference, 'WITHDRAWAL', p_amount, 'NGN')
    RETURNING transaction_id INTO v_tx;
    INSERT INTO ledger_entry (transaction_id, account_id, line_number, entry_type, amount) VALUES
        (v_tx, v_account.account_id, 1, 'DEBIT',  p_amount),
        (v_tx, v_internal,           2, 'CREDIT', p_amount);
    UPDATE financial_transaction SET status = 'POSTED', posted_at = now() WHERE transaction_id = v_tx;

    RETURN p_reference || ' posted: withdrew ' || p_amount || ' from a balance it read as ' || v_balance;
END;
$$;

-- Locks the source account first and the destination second, in request order rather
-- than a fixed order. Two opposite transfers can each hold one lock and wait for the
-- other (scenario S10). After taking both locks it posts through the safe routine.
CREATE FUNCTION unordered_transfer(p_reference VARCHAR, p_from VARCHAR, p_to VARCHAR,
                                   p_amount NUMERIC, p_think_seconds NUMERIC)
RETURNS UUID LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM account WHERE account_number = p_from FOR UPDATE;
    RAISE NOTICE '% locked % at %', p_reference, p_from, to_char(clock_timestamp(), 'HH24:MI:SS.MS');
    PERFORM pg_sleep(p_think_seconds);
    RAISE NOTICE '% now requesting lock on %', p_reference, p_to;
    PERFORM 1 FROM account WHERE account_number = p_to FOR UPDATE;
    RETURN post_two_leg('TRANSFER', 'idem-' || p_reference, p_reference, p_from, p_to, p_amount, 'demo');
END;
$$;

COMMIT;
