-- Monthly Contribution System Migration
-- Add contribution settings to groups table (one column at a time)
ALTER TABLE groups ADD COLUMN IF NOT EXISTS contribution_enabled BOOLEAN DEFAULT FALSE;
ALTER TABLE groups ADD COLUMN IF NOT EXISTS contribution_amount DECIMAL(10,2);
ALTER TABLE groups ADD COLUMN IF NOT EXISTS payment_day INTEGER;
ALTER TABLE groups ADD COLUMN IF NOT EXISTS grace_period_days INTEGER DEFAULT 3;
ALTER TABLE groups ADD COLUMN IF NOT EXISTS late_penalty_amount DECIMAL(10,2);
ALTER TABLE groups ADD COLUMN IF NOT EXISTS late_penalty_type VARCHAR(20);
ALTER TABLE groups ADD COLUMN IF NOT EXISTS auto_suspend_after INTEGER DEFAULT 2;
ALTER TABLE groups ADD COLUMN IF NOT EXISTS auto_expel_after INTEGER DEFAULT 3;

-- Add constraints
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'groups_payment_day_check') THEN
    ALTER TABLE groups ADD CONSTRAINT groups_payment_day_check CHECK (payment_day BETWEEN 1 AND 28);
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'groups_late_penalty_type_check') THEN
    ALTER TABLE groups ADD CONSTRAINT groups_late_penalty_type_check CHECK (late_penalty_type IN ('fixed', 'percentage'));
  END IF;
END $$;
