-- Fix search_path security warnings for functions

-- Drop and recreate with secure search_path
DROP FUNCTION IF EXISTS update_cycle_collected_amount() CASCADE;
CREATE OR REPLACE FUNCTION update_cycle_collected_amount()
RETURNS TRIGGER 
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
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
$$;

DROP FUNCTION IF EXISTS update_member_stats() CASCADE;
CREATE OR REPLACE FUNCTION update_member_stats()
RETURNS TRIGGER 
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
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
$$;

-- Recreate triggers
DROP TRIGGER IF EXISTS update_cycle_on_payment ON member_contributions;
CREATE TRIGGER update_cycle_on_payment
  AFTER INSERT OR UPDATE OF paid_amount ON member_contributions
  FOR EACH ROW
  EXECUTE FUNCTION update_cycle_collected_amount();

DROP TRIGGER IF EXISTS update_member_on_payment ON member_contributions;
CREATE TRIGGER update_member_on_payment
  AFTER UPDATE OF payment_status ON member_contributions
  FOR EACH ROW
  EXECUTE FUNCTION update_member_stats();
