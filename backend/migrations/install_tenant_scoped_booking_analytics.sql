-- Rebuild the legacy booking analytics view with explicit provider-tenant ownership.
-- The analytics API must filter this column before aggregating or returning data.
CREATE OR REPLACE VIEW booking_analytics AS
SELECT
    p.id AS property_id,
    p.title AS property_title,
    p.owner_id,
    COUNT(b.id) AS total_bookings,
    COUNT(CASE WHEN b.status = 'confirmed' THEN 1 END) AS confirmed_bookings,
    COUNT(CASE WHEN b.status = 'cancelled' THEN 1 END) AS cancelled_bookings,
    COUNT(CASE WHEN b.status = 'pending_payment' THEN 1 END) AS pending_payment_bookings,
    COUNT(CASE WHEN b.status = 'pending' THEN 1 END) AS pending_bookings,
    COUNT(CASE WHEN b.status = 'completed' THEN 1 END) AS completed_bookings,
    SUM(CASE WHEN b.payment_status = 'paid' THEN b.total_amount ELSE 0 END) AS total_revenue,
    SUM(CASE WHEN b.status = 'pending' AND b.payment_status = 'paid' THEN b.total_amount ELSE 0 END) AS pending_revenue,
    SUM(CASE WHEN b.status = 'pending_payment' THEN b.total_amount ELSE 0 END) AS pending_payment_revenue,
    AVG(CASE WHEN b.status IN ('confirmed', 'completed') THEN b.end_date - b.start_date END) AS avg_booking_duration,
    ROUND(COUNT(CASE WHEN b.status = 'cancelled' THEN 1 END)::DECIMAL / NULLIF(COUNT(b.id), 0) * 100, 2) AS cancellation_rate,
    ROUND(COUNT(CASE WHEN b.status IN ('confirmed', 'completed') THEN 1 END)::DECIMAL /
      NULLIF(COUNT(CASE WHEN b.status != 'cancelled' THEN 1 END), 0) * 100, 2) AS occupancy_rate,
    p.organization_id
FROM properties p
LEFT JOIN bookings b
  ON p.id = b.property_id
 AND b.provider_organization_id = p.organization_id
 AND b.deleted_at IS NULL
WHERE p.is_active = true
GROUP BY p.organization_id, p.id, p.title, p.owner_id;