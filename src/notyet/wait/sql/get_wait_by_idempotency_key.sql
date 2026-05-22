SELECT
  id::text,
  activity::text,
  idempotency_key,
  status,
  for_duration,
  to_char(wait_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS wait_until,
  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
  COALESCE(data::text, '') AS data
FROM waits
WHERE idempotency_key = $1;
