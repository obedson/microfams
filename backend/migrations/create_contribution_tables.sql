-- Create contribution cycles table
CREATE TABLE IF NOT EXISTS contribution_cycles (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
  cycle_month INTEGER CHECK (cycle_month BETWEEN 1 AND 12),
  cycle_year INTEGER,
  expected_amount DECIMAL(10,2) NOT NULL,
  collected_amount DECIMAL(10,2) DEFAULT 0,
  outstanding_amount DECIMAL(10,2),
  deadline_date DATE NOT NULL,
  status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'completed', 'overdue')),
  created_at TIMESTAMP DEFAULT NOW(),
  UNIQUE(group_id, cycle_month, cycle_year)
);

CREATE INDEX IF NOT EXISTS idx_cycles_group ON contribution_cycles(group_id);
CREATE INDEX IF NOT EXISTS idx_cycles_status ON contribution_cycles(status);

-- Create member contributions table
CREATE TABLE IF NOT EXISTS member_contributions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  cycle_id UUID REFERENCES contribution_cycles(id) ON DELETE CASCADE,
  member_id UUID REFERENCES group_members(id) ON DELETE CASCADE,
  expected_amount DECIMAL(10,2) NOT NULL,
  paid_amount DECIMAL(10,2) DEFAULT 0,
  penalty_amount DECIMAL(10,2) DEFAULT 0,
  payment_status VARCHAR(20) DEFAULT 'pending' CHECK (payment_status IN ('pending', 'paid', 'late', 'overdue', 'defaulted')),
  paid_at TIMESTAMP,
  payment_reference VARCHAR(100),
  is_late BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP DEFAULT NOW(),
  UNIQUE(cycle_id, member_id)
);

CREATE INDEX IF NOT EXISTS idx_contributions_cycle ON member_contributions(cycle_id);
CREATE INDEX IF NOT EXISTS idx_contributions_member ON member_contributions(member_id);
CREATE INDEX IF NOT EXISTS idx_contributions_status ON member_contributions(payment_status);

-- Update group_members table
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name='group_members' AND column_name='member_status') THEN
    ALTER TABLE group_members ADD COLUMN member_status VARCHAR(20) DEFAULT 'active' 
      CHECK (member_status IN ('active', 'warning', 'suspended', 'expelled'));
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name='group_members' AND column_name='missed_payments_count') THEN
    ALTER TABLE group_members ADD COLUMN missed_payments_count INTEGER DEFAULT 0;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name='group_members' AND column_name='total_contributions') THEN
    ALTER TABLE group_members ADD COLUMN total_contributions DECIMAL(10,2) DEFAULT 0;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name='group_members' AND column_name='last_payment_date') THEN
    ALTER TABLE group_members ADD COLUMN last_payment_date TIMESTAMP;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_members_status ON group_members(member_status);

-- Function to update cycle collected amount
CREATE OR REPLACE FUNCTION update_cycle_collected_amount()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE contribution_cycles
  SET 
    collected_amount = (
      SELECT COALESCE(SUM(paid_amount), 0)
      FROM member_contributions
      WHERE cycle_id = NEW.cycle_id
    ),
    outstanding_amount = expected_amount - (
      SELECT COALESCE(SUM(paid_amount), 0)
      FROM member_contributions
      WHERE cycle_id = NEW.cycle_id
    )
  WHERE id = NEW.cycle_id;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to update cycle amounts when payment is made
DROP TRIGGER IF EXISTS update_cycle_on_payment ON member_contributions;
CREATE TRIGGER update_cycle_on_payment
  AFTER INSERT OR UPDATE OF paid_amount ON member_contributions
  FOR EACH ROW
  EXECUTE FUNCTION update_cycle_collected_amount();

-- Function to update member stats
CREATE OR REPLACE FUNCTION update_member_stats()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.payment_status = 'paid' OR NEW.payment_status = 'late' THEN
    UPDATE group_members
    SET 
      total_contributions = total_contributions + NEW.paid_amount,
      last_payment_date = NEW.paid_at,
      missed_payments_count = GREATEST(0, missed_payments_count - 1)
    WHERE id = NEW.member_id;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to update member stats on payment
DROP TRIGGER IF EXISTS update_member_on_payment ON member_contributions;
CREATE TRIGGER update_member_on_payment
  AFTER UPDATE OF payment_status ON member_contributions
  FOR EACH ROW
  EXECUTE FUNCTION update_member_stats();
