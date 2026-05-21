--- migration:up
CREATE TABLE waits (
    id              UUID PRIMARY KEY,
    activity        UUID NOT NULL,
    idempotency_key TEXT NOT NULL,
    data            JSONB,
    for_duration    TEXT NOT NULL,
    wait_until      TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'accepted' CHECK (status IN ('accepted', 'waiting')),
    created_at      TIMESTAMPTZ NOT NULL
);

CREATE INDEX waits_activity_idx ON waits (activity);
CREATE UNIQUE INDEX waits_idempotency_key_idx ON waits (idempotency_key);

--- migration:down
DROP TABLE waits;

--- migration:end