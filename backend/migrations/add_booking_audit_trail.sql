-- Add audit trail columns to bookings table
ALTER TABLE bookings 
ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS cancelled_by UUID REFERENCES users(id),
ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMP WITH TIME ZONE;

-- Create booking status history table for audit trail
CREATE TABLE IF NOT EXISTS booking_status_history (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
  old_status VARCHAR(20),
  new_status VARCHAR(20) NOT NULL,
  changed_by UUID REFERENCES users(id),
  reason TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create index for faster queries
CREATE INDEX IF NOT EXISTS idx_booking_status_history_booking_id ON booking_status_history(booking_id);
CREATE INDEX IF NOT EXISTS idx_bookings_deleted_at ON bookings(deleted_at);

-- Function to log status changes
CREATE OR REPLACE FUNCTION log_booking_status_change()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO booking_status_history (booking_id, old_status, new_status, reason)
    VALUES (NEW.id, OLD.status, NEW.status, NEW.rejection_reason);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for status changes
DROP TRIGGER IF EXISTS booking_status_change_trigger ON bookings;
CREATE TRIGGER booking_status_change_trigger
  AFTER UPDATE ON bookings
  FOR EACH ROW
  EXECUTE FUNCTION log_booking_status_change();
