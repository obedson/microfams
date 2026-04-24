-- Migration: Add Profile, NIN, and Subscription fields to Users
-- Requirement: 8.1, 8.2, 8.3, 8.4 from tasks.md

-- Add new columns to users table
ALTER TABLE users 
ADD COLUMN IF NOT EXISTS nin_number VARCHAR(11) UNIQUE,
ADD COLUMN IF NOT EXISTS nin_verified BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS nin_full_name VARCHAR(255),
ADD COLUMN IF NOT EXISTS nin_date_of_birth DATE,
ADD COLUMN IF NOT EXISTS nin_gender VARCHAR(20),
ADD COLUMN IF NOT EXISTS nin_address TEXT,
ADD COLUMN IF NOT EXISTS nin_phone VARCHAR(20),
ADD COLUMN IF NOT EXISTS profile_picture_url TEXT,
ADD COLUMN IF NOT EXISTS is_platform_subscriber BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS subscription_paid_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS subscription_reference VARCHAR(100) UNIQUE,
ADD COLUMN IF NOT EXISTS grace_period_ends_at TIMESTAMPTZ;

-- Constraint: nin_verified can only be true if nin_number is present and 11 digits
ALTER TABLE users
ADD CONSTRAINT chk_nin_verified_has_number 
CHECK (
  (nin_verified = false) OR 
  (nin_verified = true AND nin_number IS NOT NULL AND LENGTH(nin_number) = 11)
);

-- Table: Group Member Action Votes (Requirement 8.2)
CREATE TABLE IF NOT EXISTS group_member_action_votes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  target_user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  voter_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  action_type     VARCHAR(20) NOT NULL CHECK (action_type IN ('SUSPEND', 'EXPEL')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  -- Ensure a user can only vote once per target per action type in a group
  UNIQUE(group_id, target_user_id, voter_id, action_type)
);

-- Index for fast vote counting
CREATE INDEX IF NOT EXISTS idx_group_member_votes_target 
ON group_member_action_votes(group_id, target_user_id, action_type);
