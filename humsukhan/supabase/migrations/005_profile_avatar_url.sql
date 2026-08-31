-- ============================================
-- Add avatar_url column to profiles table
-- ============================================

-- Add avatar_url column for storing the profile picture URL.
-- NULL means the user has no custom picture (use emoji fallback).
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT DEFAULT NULL;

-- Update the upsert trigger to include avatar_url if present.
-- The existing handle_new_user() trigger is unaffected because it
-- only sets name on creation; avatar_url starts as NULL.
