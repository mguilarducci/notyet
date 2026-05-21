INSERT INTO waits (id, activity, idempotency_key, data, for_duration, wait_until, created_at)
SELECT i::uuid, a::uuid, k, NULLIF(d, '')::jsonb, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[])
  AS t(i, a, k, d, f, w, c)
ON CONFLICT (idempotency_key) DO UPDATE SET id = waits.id
RETURNING
  id,
  activity,
  idempotency_key,
  status,
  created_at AT TIME ZONE 'UTC' AS created_at,
  wait_until AT TIME ZONE 'UTC' AS wait_until;
