--- migration:up
CREATE TABLE waits (
    id           UUID PRIMARY KEY,
    activity     UUID NOT NULL,
    data         JSONB,
    for_duration TEXT NOT NULL,
    wait_until   TIMESTAMPTZ NOT NULL,
    status       TEXT NOT NULL DEFAULT 'received' CHECK (status IN ('received', 'waiting')),
    created_at   TIMESTAMPTZ NOT NULL
);

CREATE INDEX waits_activity_idx ON waits (activity);

--- migration:down
DROP TABLE waits;

--- migration:end