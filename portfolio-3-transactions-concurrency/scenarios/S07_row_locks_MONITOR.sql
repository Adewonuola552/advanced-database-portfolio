\echo 'MONITOR: which sessions are waiting, on what, and who blocks them'
SELECT pid, state, wait_event_type, wait_event, pg_blocking_pids(pid) AS blocked_by, left(query, 70) AS query
  FROM pg_stat_activity
 WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend'
 ORDER BY backend_start;
SELECT l.pid, c.relname, l.locktype, l.mode, l.granted
  FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
 WHERE c.relname = 'account' AND l.pid <> pg_backend_pid()
 ORDER BY l.pid, l.mode;
