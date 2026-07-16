-- Create atomic group creation with payment
-- This ensures group and membership are created together or not at all

CREATE OR REPLACE FUNCTION create_group_with_creator(
  p_name TEXT,
  p_description TEXT,
  p_category TEXT,
  p_creator_id UUID,
  p_state_id INTEGER,
  p_lga_id INTEGER,
  p_entry_fee INTEGER,
  p_max_members INTEGER,
  p_payment_reference TEXT,
  p_amount_paid INTEGER
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_group_id UUID;
  v_member_id UUID;
  v_result JSON;
BEGIN
  -- Check if payment reference already used
  IF EXISTS (
    SELECT 1 FROM group_members 
    WHERE payment_reference = p_payment_reference
  ) THEN
    RAISE EXCEPTION 'Payment reference already used';
  END IF;

  -- Create group
  INSERT INTO groups (
    name, 
    description, 
    category, 
    creator_id, 
    state_id, 
    lga_id, 
    entry_fee,
    max_members,
    member_count,
    is_active
  ) VALUES (
    p_name,
    p_description,
    p_category,
    p_creator_id,
    p_state_id,
    p_lga_id,
    p_entry_fee,
    COALESCE(p_max_members, 50),
    1, -- Creator is first member
    true
  )
  RETURNING id INTO v_group_id;

  -- Add creator as first member with paid status
  INSERT INTO group_members (
    group_id,
    user_id,
    payment_reference,
    amount_paid,
    payment_status,
    paid_at
  ) VALUES (
    v_group_id,
    p_creator_id,
    p_payment_reference,
    p_amount_paid,
    'paid',
    NOW()
  )
  RETURNING id INTO v_member_id;

  -- Return result
  SELECT json_build_object(
    'group_id', v_group_id,
    'member_id', v_member_id,
    'success', true
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- Add unique constraint on payment_reference
ALTER TABLE group_members 
ADD CONSTRAINT unique_payment_reference 
UNIQUE (payment_reference);

-- Add index for faster lookups
CREATE INDEX IF NOT EXISTS idx_group_members_payment_ref 
ON group_members(payment_reference);
