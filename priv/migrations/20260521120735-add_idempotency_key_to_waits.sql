--- migration:up
ALTER TABLE waits ADD COLUMN idempotency_key TEXT;
UPDATE waits SET idempotency_key = id::text WHERE idempotency_key IS NULL;
ALTER TABLE waits ALTER COLUMN idempotency_key SET NOT NULL;
CREATE UNIQUE INDEX waits_idempotency_key_idx ON waits (idempotency_key);

--- migration:down
DROP INDEX waits_idempotency_key_idx;
ALTER TABLE waits DROP COLUMN idempotency_key;

--- migration:end
