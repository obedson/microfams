-- Add is_suspended column to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_suspended BOOLEAN DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_users_suspended ON users(is_suspended);
