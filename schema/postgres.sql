-- P-A-R PostgreSQL Schema

CREATE TABLE IF NOT EXISTS events (
  id                TEXT PRIMARY KEY,
  task_id           TEXT NOT NULL,
  payload           JSONB NOT NULL,
  timestamp         DOUBLE PRECISION NOT NULL,
  idempotency_key   TEXT UNIQUE NOT NULL,
  delivery_attempt  INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_events_task_id ON events(task_id);
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);

CREATE TABLE IF NOT EXISTS task_states (
  id          TEXT PRIMARY KEY,
  state       JSONB NOT NULL,
  updated_at  DOUBLE PRECISION NOT NULL
);

CREATE TABLE IF NOT EXISTS dead_letters (
  id              TEXT PRIMARY KEY,
  envelope        JSONB NOT NULL,
  error           TEXT NOT NULL,
  failure_reason  TEXT NOT NULL,
  failed_at       DOUBLE PRECISION NOT NULL,
  attempt_count   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS workflow_states (
  id          TEXT PRIMARY KEY,
  workflow_id TEXT NOT NULL,
  status      TEXT NOT NULL,
  checkpoint  JSONB,
  updated_at  DOUBLE PRECISION NOT NULL
);
