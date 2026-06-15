CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  payload TEXT NOT NULL,
  timestamp REAL NOT NULL,
  idempotency_key TEXT UNIQUE NOT NULL,
  delivery_attempt INTEGER DEFAULT 0,
  session_id TEXT NOT NULL DEFAULT '',
  actions_json TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_task_id ON events(task_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
CREATE INDEX IF NOT EXISTS idx_events_session_id ON events(session_id, timestamp);

CREATE TABLE IF NOT EXISTS task_states (
  id TEXT PRIMARY KEY,
  state TEXT NOT NULL,
  updated_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS dead_letters (
  id TEXT PRIMARY KEY,
  envelope TEXT NOT NULL,
  error TEXT NOT NULL,
  failure_reason TEXT NOT NULL,
  failed_at REAL NOT NULL,
  attempt_count INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS workflow_states (
  id TEXT PRIMARY KEY,
  workflow_id TEXT NOT NULL,
  status TEXT NOT NULL,
  checkpoint TEXT,
  updated_at REAL NOT NULL
);
