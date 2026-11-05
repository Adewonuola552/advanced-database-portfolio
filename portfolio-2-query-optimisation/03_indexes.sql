-- Indexes added after the baseline measurements. Each targets specific queries in
-- 02_queries.sql. Primary keys and unique constraints already have their own indexes.

-- Q1, Q2, Q3, Q4: finds one account's entries, optionally within a date range, without
-- scanning the whole ledger.
CREATE INDEX idx_ledger_account_created
    ON ledger_entry (account_id, created_at DESC);

-- Q4: finds a customer's accounts. PostgreSQL does not index foreign keys automatically.
CREATE INDEX idx_account_customer
    ON account (customer_id);

-- Q7: finds ledger entries in a date range.
CREATE INDEX idx_ledger_created
    ON ledger_entry (created_at);

-- Q5: partial index holding posted transactions only. Finance reports never read the
-- other statuses.
CREATE INDEX idx_ft_posted_at
    ON financial_transaction (posted_at)
    WHERE status = 'POSTED';

-- Q6: partial index on a rare status, so it stays very small.
CREATE INDEX idx_ft_pending_created
    ON financial_transaction (created_at)
    WHERE status = 'PENDING';

-- Q8: GIN index for JSONB containment (@>). jsonb_path_ops is smaller than the default
-- operator class and supports only the containment operators this query needs.
CREATE INDEX idx_audit_details
    ON audit_log USING gin (details jsonb_path_ops);
