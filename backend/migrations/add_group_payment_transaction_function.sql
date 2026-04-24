-- Transaction-safe group payment confirmation
-- Ensures member count and payment status are updated atomically

CREATE OR REPLACE FUNCTION confirm_group_payment_transaction(
  p_member_id UUID
) RETURNS group_members AS $$
DECLARE
  v_member group_members;
BEGIN
  -- Update member payment status
  UPDATE group_members
  SET 
    payment_status = 'paid',
    paid_at = NOW()
  WHERE id = p_member_id
  RETURNING * INTO v_member;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Member not found';
  END IF;

  -- Increment group member count
  UPDATE groups
  SET member_count = member_count + 1
  WHERE id = v_member.group_id;

  RETURN v_member;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION confirm_group_payment_transaction TO authenticated;
