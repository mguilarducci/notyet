INSERT INTO waits (id, activity, data, for_duration, wait_until, created_at)
SELECT i::uuid, a::uuid, NULLIF(d, '')::jsonb, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[])
  AS t(i, a, d, f, w, c)
RETURNING id;
