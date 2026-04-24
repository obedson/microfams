-- Refunds table
CREATE TABLE IF NOT EXISTS refunds (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
  amount DECIMAL(10,2) NOT NULL,
  reason TEXT,
  status VARCHAR(20) CHECK (status IN ('pending', 'processed', 'failed')) DEFAULT 'pending',
  payment_reference VARCHAR(255),
  processed_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_refunds_booking_id ON refunds(booking_id);
CREATE INDEX idx_refunds_status ON refunds(status);
