SELECT
  id::text,
  idempotency_key,
  status,
  wait_for,
  target_kind,
  target_config::text AS target_config,
  to_char(wait_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS wait_until,
  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at
FROM tasks
WHERE idempotency_key = $1;
