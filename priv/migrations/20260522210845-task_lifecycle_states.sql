--- migration:up
ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_status_check;
UPDATE tasks SET status = 'pending' WHERE status = 'accepted';
ALTER TABLE tasks
  ADD CONSTRAINT tasks_status_check
  CHECK (status IN ('pending', 'delivering', 'delivered', 'failed'));
ALTER TABLE tasks ALTER COLUMN status SET DEFAULT 'pending';

ALTER TABLE tasks ADD COLUMN visible_at TIMESTAMPTZ;
UPDATE tasks SET visible_at = wait_until;
ALTER TABLE tasks ALTER COLUMN visible_at SET NOT NULL;

CREATE INDEX tasks_status_visible_at_idx ON tasks (status, visible_at);

--- migration:down
DROP INDEX tasks_status_visible_at_idx;
ALTER TABLE tasks DROP COLUMN visible_at;
ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_status_check;
UPDATE tasks SET status = 'accepted' WHERE status = 'pending';
ALTER TABLE tasks
  ADD CONSTRAINT tasks_status_check
  CHECK (status IN ('accepted', 'waiting'));
ALTER TABLE tasks ALTER COLUMN status SET DEFAULT 'accepted';

--- migration:end
