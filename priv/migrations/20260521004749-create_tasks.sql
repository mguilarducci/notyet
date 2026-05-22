--- migration:up
CREATE TABLE tasks (
    id              UUID PRIMARY KEY,
    idempotency_key TEXT NOT NULL,
    wait_for        TEXT NOT NULL,
    destination     TEXT NOT NULL,
    wait_until      TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'accepted' CHECK (status IN ('accepted', 'waiting')),
    created_at      TIMESTAMPTZ NOT NULL
);

CREATE UNIQUE INDEX tasks_idempotency_key_idx ON tasks (idempotency_key);

--- migration:down
DROP TABLE tasks;

--- migration:end
