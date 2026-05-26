--- migration:up
CREATE TABLE tasks (
    id              UUID PRIMARY KEY,
    idempotency_key TEXT NOT NULL,
    wait_for        TEXT NOT NULL,
    target_kind     TEXT NOT NULL CHECK (target_kind IN ('webhook')),
    target_config   JSONB NOT NULL,
    wait_until      TIMESTAMPTZ NOT NULL,
    visible_at      TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'delivering', 'delivered', 'failed')),
    created_at      TIMESTAMPTZ NOT NULL,
    CONSTRAINT tasks_webhook_config_check CHECK (
      target_kind <> 'webhook' OR (
            target_config ? 'url'     AND jsonb_typeof(target_config->'url')     = 'string'
        AND target_config ? 'method'  AND target_config->>'method' IN ('GET','POST','PUT','PATCH','DELETE')
        AND target_config ? 'headers' AND jsonb_typeof(target_config->'headers') = 'object'
        AND (NOT target_config ? 'body' OR jsonb_typeof(target_config->'body') = 'string')
      )
    )
);

CREATE UNIQUE INDEX tasks_idempotency_key_idx ON tasks (idempotency_key);
CREATE INDEX tasks_status_visible_at_idx ON tasks (status, visible_at);

--- migration:down
DROP TABLE tasks;

--- migration:end
