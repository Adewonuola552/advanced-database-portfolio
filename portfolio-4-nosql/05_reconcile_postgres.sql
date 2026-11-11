-- Summary of the PostgreSQL source, in the same line format as 05_reconcile_mongo.js,
-- so that the two outputs can be compared with diff.
\pset format unaligned
\pset tuples_only on
SELECT 'count customers=' || count(*) FROM customer
UNION ALL SELECT 'count accounts=' || count(*) FROM account
UNION ALL SELECT 'count audit_events=' || count(*) FROM audit_log
UNION ALL
SELECT format('transactions %s %s count=%s amount=%s legs=%s',
              ft.status, ft.transaction_type, count(*), sum(ft.amount), sum(coalesce(e.n, 0)))
  FROM financial_transaction ft
  LEFT JOIN (SELECT transaction_id, count(*) AS n FROM ledger_entry GROUP BY 1) e USING (transaction_id)
 GROUP BY ft.status, ft.transaction_type
UNION ALL
SELECT format('balances %s %s accounts=%s total=%s min=%s max=%s',
              a.account_kind, a.currency_code, count(*), sum(b.balance), min(b.balance), max(b.balance))
  FROM account a
  CROSS JOIN LATERAL (
        SELECT coalesce(sum(CASE WHEN le.entry_type = 'CREDIT' THEN le.amount ELSE -le.amount END), 0)::NUMERIC(18,2) AS balance
          FROM ledger_entry le JOIN financial_transaction ft USING (transaction_id)
         WHERE le.account_id = a.account_id AND ft.status = 'POSTED') b
 GROUP BY a.account_kind, a.currency_code;
