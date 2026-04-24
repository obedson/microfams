-- Add pending_payment status to bookings
-- This allows bookings to be created before payment is completed

-- First, check current constraint name
DO $$ 
DECLARE
  constraint_name_var TEXT;
BEGIN
  SELECT conname INTO constraint_name_var
  FROM pg_constraint
  WHERE conrelid = 'bookings'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%status%'
    AND pg_get_constraintdef(oid) LIKE '%pending%confirmed%'
  LIMIT 1;
  
  IF constraint_name_var IS NOT NULL THEN
    EXECUTE 'ALTER TABLE bookings DROP CONSTRAINT ' || constraint_name_var;
    RAISE NOTICE 'Dropped constraint: %', constraint_name_var;
  END IF;
END $$;

-- Add new constraint with pending_payment status
ALTER TABLE bookings 
ADD CONSTRAINT bookings_status_check 
CHECK (status IN ('pending_payment', 'pending', 'confirmed', 'cancelled', 'completed'));
