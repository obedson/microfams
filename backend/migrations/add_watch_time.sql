-- Add watch time tracking
ALTER TABLE user_progress ADD COLUMN IF NOT EXISTS watch_time_seconds INTEGER DEFAULT 0;
ALTER TABLE user_progress ADD COLUMN IF NOT EXISTS last_watched_at TIMESTAMP;
