-- ============================================
-- 004: Insight source & language metadata
--
-- Distinguishes AI-generated insights from the local keyword-extraction
-- fallback, and records the transcript language that was analysed.
-- ============================================

-- Source: 0 = ai (Gemini), 1 = local (offline keyword extraction).
-- Default 1 so existing rows (created before this column) are treated
-- as local fallback, matching the previous behaviour.
ALTER TABLE insights
  ADD COLUMN IF NOT EXISTS source INTEGER DEFAULT 1;

-- The language of the transcript that was analysed (e.g. 'English',
-- 'Urdu', 'Hindi', 'Roman Urdu'). Defaults to 'English' for existing rows.
ALTER TABLE insights
  ADD COLUMN IF NOT EXISTS language TEXT DEFAULT 'English';
