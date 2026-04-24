-- Farmle Platform Enhancement - Database Schema Migration
-- Task 1: Database schema enhancements and infrastructure setup
-- This migration adds new columns, tables, indexes, views, and functions for the enhanced platform

-- =============================================================================
-- PHASE 1: ENHANCE EXISTING BOOKINGS TABLE
-- =============================================================================

-- Add new columns to existing bookings table for payment retry functionality
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS payment_retry_count INTEGER DEFAULT 0;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS payment_timeout_at TIMESTAMP WITH TIME ZONE;

-- Add indexes for new functionality
CREATE INDEX IF NOT EXISTS idx_bookings_payment_retry ON bookings(payment_retry_count) WHERE payment_retry_count > 0;
CREATE INDEX IF NOT EXISTS idx_bookings_timeout ON bookings(payment_timeout_at) WHERE payment_timeout_at IS NOT NULL;

-- =============================================================================
-- PHASE 2: CREATE NEW TABLES
-- =============================================================================

-- Analytics cache table for performance optimization
CREATE TABLE IF NOT EXISTS analytics_cache (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cache_key VARCHAR(255) UNIQUE NOT NULL,
    data JSONB NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_analytics_cache_key ON analytics_cache(cache_key);
CREATE INDEX IF NOT EXISTS idx_analytics_cache_expires ON analytics_cache(expires_at);

-- Communication log table for in-app messaging
CREATE TABLE IF NOT EXISTS booking_communications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES users(id) ON DELETE CASCADE,
    recipient_id UUID REFERENCES users(id) ON DELETE CASCADE,
    message_type VARCHAR(50) NOT NULL CHECK (message_type IN ('booking_inquiry', 'booking_update', 'payment_reminder', 'cancellation_notice', 'general')),
    subject TEXT,
    content TEXT NOT NULL,
    read_at TIMESTAMP WITH TIME ZONE,
    sent_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_communications_booking ON booking_communications(booking_id);
CREATE INDEX IF NOT EXISTS idx_communications_sender ON booking_communications(sender_id);
CREATE INDEX IF NOT EXISTS idx_communications_recipient ON booking_communications(recipient_id);
CREATE INDEX IF NOT EXISTS idx_communications_unread ON booking_communications(recipient_id, read_at) WHERE read_at IS NULL;

-- Receipt records table for PDF receipt generation
CREATE TABLE IF NOT EXISTS payment_receipts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
    payment_reference VARCHAR(255) NOT NULL,
    receipt_number VARCHAR(100) UNIQUE NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    currency VARCHAR(3) DEFAULT 'NGN',
    generated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    pdf_url TEXT,
    qr_code TEXT
);

CREATE INDEX IF NOT EXISTS idx_receipts_booking ON payment_receipts(booking_id);
CREATE INDEX IF NOT EXISTS idx_receipts_payment_ref ON payment_receipts(payment_reference);
CREATE UNIQUE INDEX IF NOT EXISTS idx_receipts_number ON payment_receipts(receipt_number);

-- =============================================================================
-- PHASE 3: CREATE ANALYTICS VIEWS AND FUNCTIONS
-- =============================================================================

-- Enhanced analytics view for performance optimization
CREATE OR REPLACE VIEW booking_analytics AS
SELECT 
    p.id as property_id,
    p.title as property_title,
    p.owner_id,
    COUNT(b.id) as total_bookings,
    COUNT(CASE WHEN b.status = 'confirmed' THEN 1 END) as confirmed_bookings,
    COUNT(CASE WHEN b.status = 'cancelled' THEN 1 END) as cancelled_bookings,
    COUNT(CASE WHEN b.status = 'pending_payment' THEN 1 END) as pending_payment_bookings,
    COUNT(CASE WHEN b.status = 'pending' THEN 1 END) as pending_bookings,
    COUNT(CASE WHEN b.status = 'completed' THEN 1 END) as completed_bookings,
    SUM(CASE WHEN b.payment_status = 'paid' THEN b.total_amount ELSE 0 END) as total_revenue,
    SUM(CASE WHEN b.status = 'pending' AND b.payment_status = 'paid' THEN b.total_amount ELSE 0 END) as pending_revenue,
    SUM(CASE WHEN b.status = 'pending_payment' THEN b.total_amount ELSE 0 END) as pending_payment_revenue,
    AVG(CASE WHEN b.status IN ('confirmed', 'completed') THEN b.end_date - b.start_date END) as avg_booking_duration,
    ROUND(
        COUNT(CASE WHEN b.status = 'cancelled' THEN 1 END)::DECIMAL / 
        NULLIF(COUNT(b.id), 0) * 100, 2
    ) as cancellation_rate,
    ROUND(
        COUNT(CASE WHEN b.status IN ('confirmed', 'completed') THEN 1 END)::DECIMAL / 
        NULLIF(COUNT(CASE WHEN b.status != 'cancelled' THEN 1 END), 0) * 100, 2
    ) as occupancy_rate
FROM properties p
LEFT JOIN bookings b ON p.id = b.property_id AND b.deleted_at IS NULL
WHERE p.is_active = true
GROUP BY p.id, p.title, p.owner_id;

-- Function to generate unique receipt numbers
CREATE OR REPLACE FUNCTION generate_receipt_number() RETURNS TEXT AS $$
DECLARE
    receipt_num TEXT;
    counter INTEGER := 1;
BEGIN
    LOOP
        receipt_num := 'RCP-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD(counter::TEXT, 4, '0');
        
        IF NOT EXISTS (SELECT 1 FROM payment_receipts WHERE receipt_number = receipt_num) THEN
            RETURN receipt_num;
        END IF;
        
        counter := counter + 1;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Trigger to auto-generate receipt numbers
CREATE OR REPLACE FUNCTION auto_generate_receipt_number() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.receipt_number IS NULL THEN
        NEW.receipt_number := generate_receipt_number();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER receipt_number_trigger
    BEFORE INSERT ON payment_receipts
    FOR EACH ROW
    EXECUTE FUNCTION auto_generate_receipt_number();

-- =============================================================================
-- PHASE 4: PERFORMANCE OPTIMIZATION INDEXES
-- =============================================================================

-- Additional performance indexes for new query patterns
CREATE INDEX IF NOT EXISTS idx_bookings_status_payment_status ON bookings(status, payment_status);
CREATE INDEX IF NOT EXISTS idx_bookings_created_at_desc ON bookings(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bookings_farmer_status ON bookings(farmer_id, status);
CREATE INDEX IF NOT EXISTS idx_bookings_property_status ON bookings(property_id, status);

-- Indexes for analytics performance
CREATE INDEX IF NOT EXISTS idx_bookings_analytics ON bookings(property_id, status, payment_status, total_amount) WHERE deleted_at IS NULL;

-- =============================================================================
-- PHASE 5: UTILITY FUNCTIONS FOR ANALYTICS
-- =============================================================================

-- Function to calculate property occupancy rate
CREATE OR REPLACE FUNCTION calculate_occupancy_rate(
    property_id_param UUID,
    start_date_param DATE DEFAULT NULL,
    end_date_param DATE DEFAULT NULL
) RETURNS DECIMAL AS $$
DECLARE
    total_days INTEGER;
    booked_days INTEGER;
    occupancy_rate DECIMAL;
BEGIN
    -- Set default date range if not provided (last 12 months)
    IF start_date_param IS NULL THEN
        start_date_param := CURRENT_DATE - INTERVAL '12 months';
    END IF;
    
    IF end_date_param IS NULL THEN
        end_date_param := CURRENT_DATE;
    END IF;
    
    -- Calculate total available days
    total_days := end_date_param - start_date_param;
    
    -- Calculate booked days (confirmed and completed bookings only)
    SELECT COALESCE(SUM(
        LEAST(b.end_date, end_date_param) - GREATEST(b.start_date, start_date_param) + 1
    ), 0) INTO booked_days
    FROM bookings b
    WHERE b.property_id = property_id_param
      AND b.status IN ('confirmed', 'completed')
      AND b.deleted_at IS NULL
      AND b.start_date <= end_date_param
      AND b.end_date >= start_date_param;
    
    -- Calculate occupancy rate
    IF total_days > 0 THEN
        occupancy_rate := ROUND((booked_days::DECIMAL / total_days) * 100, 2);
    ELSE
        occupancy_rate := 0;
    END IF;
    
    RETURN occupancy_rate;
END;
$$ LANGUAGE plpgsql;

-- Function to get booking conversion rate (pending_payment to confirmed)
CREATE OR REPLACE FUNCTION calculate_conversion_rate(
    property_id_param UUID DEFAULT NULL,
    start_date_param DATE DEFAULT NULL,
    end_date_param DATE DEFAULT NULL
) RETURNS DECIMAL AS $$
DECLARE
    total_bookings INTEGER;
    confirmed_bookings INTEGER;
    conversion_rate DECIMAL;
BEGIN
    -- Set default date range if not provided (last 12 months)
    IF start_date_param IS NULL THEN
        start_date_param := CURRENT_DATE - INTERVAL '12 months';
    END IF;
    
    IF end_date_param IS NULL THEN
        end_date_param := CURRENT_DATE;
    END IF;
    
    -- Build query based on whether property filter is provided
    IF property_id_param IS NOT NULL THEN
        SELECT 
            COUNT(*),
            COUNT(CASE WHEN status IN ('confirmed', 'completed') THEN 1 END)
        INTO total_bookings, confirmed_bookings
        FROM bookings
        WHERE property_id = property_id_param
          AND deleted_at IS NULL
          AND created_at >= start_date_param
          AND created_at <= end_date_param;
    ELSE
        SELECT 
            COUNT(*),
            COUNT(CASE WHEN status IN ('confirmed', 'completed') THEN 1 END)
        INTO total_bookings, confirmed_bookings
        FROM bookings
        WHERE deleted_at IS NULL
          AND created_at >= start_date_param
          AND created_at <= end_date_param;
    END IF;
    
    -- Calculate conversion rate
    IF total_bookings > 0 THEN
        conversion_rate := ROUND((confirmed_bookings::DECIMAL / total_bookings) * 100, 2);
    ELSE
        conversion_rate := 0;
    END IF;
    
    RETURN conversion_rate;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PHASE 6: DATA INTEGRITY AND CLEANUP
-- =============================================================================

-- Add constraint to ensure payment_retry_count is non-negative
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'chk_payment_retry_count_non_negative' 
        AND table_name = 'bookings'
    ) THEN
        ALTER TABLE bookings ADD CONSTRAINT chk_payment_retry_count_non_negative 
            CHECK (payment_retry_count >= 0);
    END IF;
END $$;

-- Add constraint to ensure payment_timeout_at is in the future when set
-- (This will be enforced at application level for existing records)

-- Clean up any orphaned analytics cache entries (older than 7 days)
DELETE FROM analytics_cache WHERE expires_at < NOW() - INTERVAL '7 days';

-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================

-- Verify new columns exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'bookings' AND column_name = 'payment_retry_count'
    ) THEN
        RAISE EXCEPTION 'Migration failed: payment_retry_count column not created';
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'bookings' AND column_name = 'payment_timeout_at'
    ) THEN
        RAISE EXCEPTION 'Migration failed: payment_timeout_at column not created';
    END IF;
    
    RAISE NOTICE 'Migration verification passed: All new columns created successfully';
END $$;

-- Verify new tables exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'analytics_cache') THEN
        RAISE EXCEPTION 'Migration failed: analytics_cache table not created';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'booking_communications') THEN
        RAISE EXCEPTION 'Migration failed: booking_communications table not created';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'payment_receipts') THEN
        RAISE EXCEPTION 'Migration failed: payment_receipts table not created';
    END IF;
    
    RAISE NOTICE 'Migration verification passed: All new tables created successfully';
END $$;

-- Verify analytics view exists
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.views WHERE table_name = 'booking_analytics') THEN
        RAISE EXCEPTION 'Migration failed: booking_analytics view not created';
    END IF;
    
    RAISE NOTICE 'Migration verification passed: Analytics view created successfully';
END $$;

-- Display migration summary
SELECT 
    'Farmle Platform Enhancement Schema Migration Completed' as status,
    NOW() as completed_at,
    (
        SELECT COUNT(*) FROM information_schema.columns 
        WHERE table_name = 'bookings' AND column_name IN ('payment_retry_count', 'payment_timeout_at')
    ) as new_booking_columns,
    (
        SELECT COUNT(*) FROM information_schema.tables 
        WHERE table_name IN ('analytics_cache', 'booking_communications', 'payment_receipts')
    ) as new_tables,
    (
        SELECT COUNT(*) FROM information_schema.views 
        WHERE table_name = 'booking_analytics'
    ) as new_views;