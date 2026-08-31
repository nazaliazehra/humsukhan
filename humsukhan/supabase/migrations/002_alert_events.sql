-- ============================================
-- HumSukhan Supabase Schema – Alert Events
-- Migration 002
-- ============================================
-- Persistent, user-scoped environmental alert history.
-- The Flutter app stores alerts locally in SharedPreferences and
-- optionally syncs to this table when the user is authenticated.
-- ============================================

CREATE TABLE IF NOT EXISTS alert_events (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  confidence DOUBLE PRECISION NOT NULL DEFAULT 0.0,
  severity TEXT NOT NULL DEFAULT 'warning',
  dismissed BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================
-- INDEXES
-- ============================================
CREATE INDEX IF NOT EXISTS idx_alert_events_user_id
  ON alert_events(user_id);
CREATE INDEX IF NOT EXISTS idx_alert_events_created_at
  ON alert_events(created_at DESC);

-- ============================================
-- ROW LEVEL SECURITY
-- ============================================
ALTER TABLE alert_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own alert events"
  ON alert_events FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can manage own alert events"
  ON alert_events FOR ALL
  USING (auth.uid() = user_id);
