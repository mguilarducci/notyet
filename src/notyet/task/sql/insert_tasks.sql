INSERT INTO tasks (id, idempotency_key, wait_for, wait_until, created_at)
SELECT i::uuid, k, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[])
  AS t(i, k, f, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
