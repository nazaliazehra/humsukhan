-- ============================================
-- Add updated_at column to sessions table
-- Enables meaningful local/cloud merge comparisons
-- ============================================

ALTER TABLE sessions
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();

-- Backfill existing rows so updated_at is never NULL
UPDATE sessions SET updated_at = created_at WHERE updated_at IS NULL;

-- Keep updated_at fresh on every INSERT or UPDATE
CREATE OR REPLACE FUNCTION set_sessions_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sessions_updated_at ON sessions;
CREATE TRIGGER trg_sessions_updated_at
  BEFORE INSERT OR UPDATE ON sessions
  FOR EACH ROW EXECUTE FUNCTION set_sessions_updated_at();
