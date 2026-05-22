SELECT
  id::text,
  idempotency_key,
  status,
  wait_for,
  to_char(wait_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS wait_until,
  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
  destination
FROM tasks
WHERE idempotency_key = $1;
