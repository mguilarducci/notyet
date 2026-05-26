INSERT INTO tasks (id, idempotency_key, wait_for, target_kind, target_config, visible_at, wait_until, created_at)
SELECT i::uuid, k, f, tk, tc::jsonb, v::timestamptz, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[], $8::text[])
  AS t(i, k, f, tk, tc, v, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
