-- Transaction-safe payment recording function
-- This ensures payment updates are atomic and consistent

CREATE OR REPLACE FUNCTION record_payment_transaction(
  p_contribution_id UUID,
  p_amount DECIMAL,
  p_reference TEXT
) RETURNS member_contributions AS $$
DECLARE
  v_contribution member_contributions;
  v_deadline TIMESTAMP;
  v_grace_days INTEGER;
  v_penalty_type VARCHAR(20);
  v_penalty_amount DECIMAL;
  v_penalty DECIMAL := 0;
  v_is_late BOOLEAN := false;
  v_now TIMESTAMP := NOW();
BEGIN
  -- Get contribution details
  SELECT mc.*
  INTO v_contribution
  FROM member_contributions mc
  WHERE mc.id = p_contribution_id
  FOR UPDATE; -- Lock the row

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contribution not found';
  END IF;

  -- Get cycle and group details
  SELECT 
    cc.deadline_date,
    g.grace_period_days,
    g.late_penalty_type,
    g.late_penalty_amount
  INTO 
    v_deadline,
    v_grace_days,
    v_penalty_type,
    v_penalty_amount
  FROM contribution_cycles cc
  JOIN groups g ON cc.group_id = g.id
  WHERE cc.id = v_contribution.cycle_id;

  -- Calculate penalty if late
  IF v_now > (v_deadline + (COALESCE(v_grace_days, 0) || ' days')::INTERVAL) THEN
    v_is_late := true;
    
    IF v_penalty_type = 'percentage' THEN
      v_penalty := (v_contribution.expected_amount * v_penalty_amount / 100);
    ELSE
      v_penalty := v_penalty_amount;
    END IF;
  END IF;

  -- Update contribution record
  UPDATE member_contributions
  SET 
    paid_amount = p_amount,
    penalty_amount = v_penalty,
    payment_status = CASE WHEN v_is_late THEN 'late' ELSE 'paid' END,
    is_late = v_is_late,
    paid_at = v_now,
    payment_reference = p_reference
  WHERE id = p_contribution_id
  RETURNING * INTO v_contribution;

  -- Update cycle outstanding amount
  UPDATE contribution_cycles
  SET outstanding_amount = outstanding_amount - p_amount
  WHERE id = v_contribution.cycle_id;

  -- Reset missed payments count if paid
  UPDATE group_members
  SET missed_payments_count = 0
  WHERE id = v_contribution.member_id;

  RETURN v_contribution;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION record_payment_transaction TO authenticated;
