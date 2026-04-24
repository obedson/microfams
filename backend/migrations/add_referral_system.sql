-- Add referral system to users
ALTER TABLE users 
  ADD COLUMN referral_code VARCHAR(20) UNIQUE,
  ADD COLUMN referred_by UUID REFERENCES users(id),
  ADD COLUMN paid_referrals_count INTEGER DEFAULT 0;

-- Generate unique referral codes for existing users
UPDATE users SET referral_code = UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 8)) WHERE referral_code IS NULL;

-- Add payment tracking to group_members
ALTER TABLE group_members
  ADD COLUMN payment_status VARCHAR(20) CHECK (payment_status IN ('pending', 'paid', 'failed')) DEFAULT 'pending',
  ADD COLUMN payment_reference VARCHAR(100),
  ADD COLUMN amount_paid DECIMAL(10,2),
  ADD COLUMN paid_at TIMESTAMP;

-- Add entry fee to groups
ALTER TABLE groups
  ADD COLUMN entry_fee DECIMAL(10,2) DEFAULT 1000.00 CHECK (entry_fee >= 500 AND entry_fee <= 10000);

-- Create index for referral lookups
CREATE INDEX idx_users_referral_code ON users(referral_code);
CREATE INDEX idx_users_referred_by ON users(referred_by);

-- Function to update paid referrals count
CREATE OR REPLACE FUNCTION update_referrer_count()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.payment_status = 'paid' AND OLD.payment_status != 'paid' THEN
    -- Get the user who joined the group
    UPDATE users 
    SET paid_referrals_count = paid_referrals_count + 1
    WHERE id = (
      SELECT referred_by FROM users WHERE id = NEW.user_id
    ) AND referred_by IS NOT NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to update referrer count when member pays
CREATE TRIGGER update_referrer_on_payment
  AFTER UPDATE ON group_members
  FOR EACH ROW
  EXECUTE FUNCTION update_referrer_count();
