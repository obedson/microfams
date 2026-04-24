-- Add notes and rejection_reason columns to bookings table
ALTER TABLE bookings 
ADD COLUMN IF NOT EXISTS notes TEXT,
ADD COLUMN IF NOT EXISTS rejection_reason TEXT;

-- Create index for owner queries
CREATE INDEX IF NOT EXISTS idx_bookings_status ON bookings(status);
CREATE INDEX IF NOT EXISTS idx_bookings_payment_status ON bookings(payment_status);
CREATE INDEX IF NOT EXISTS idx_bookings_dates ON bookings(start_date, end_date);

-- Add payment_reference column if not exists
ALTER TABLE bookings 
ADD COLUMN IF NOT EXISTS payment_reference VARCHAR(255);
