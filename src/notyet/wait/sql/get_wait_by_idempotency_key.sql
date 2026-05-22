SELECT
  id::text,
  activity::text,
  idempotency_key,
  status,
  for_duration,
  wait_until::text,
  created_at::text,
  coalesce(data::text, '') AS data
FROM waits
WHERE idempotency_key = $1;
