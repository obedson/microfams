-- Payment and payout records are mutated only through the approved
-- SECURITY DEFINER commands. Custom PostgreSQL settings are caller-controlled,
-- so application roles receive read access but no direct DML privileges.

REVOKE INSERT, UPDATE, DELETE ON
  payments, payment_attempts, payment_refunds, payment_reversals, payment_fees,
  settlements, settlement_items, payment_provider_events,
  payouts, payout_attempts, provider_events
FROM service_role;

DO $$
DECLARE
  protected_table TEXT;
BEGIN
  FOREACH protected_table IN ARRAY ARRAY[
    'payments', 'payment_attempts', 'payment_refunds', 'payment_reversals',
    'payment_fees', 'settlements', 'settlement_items', 'payment_provider_events',
    'payouts', 'payout_attempts', 'provider_events'
  ] LOOP
    IF has_table_privilege('service_role', protected_table, 'INSERT')
      OR has_table_privilege('service_role', protected_table, 'UPDATE')
      OR has_table_privilege('service_role', protected_table, 'DELETE') THEN
      RAISE EXCEPTION 'service_role has direct DML privilege on %', protected_table;
    END IF;
    IF NOT has_table_privilege('service_role', protected_table, 'SELECT') THEN
      RAISE EXCEPTION 'service_role cannot service existing % records', protected_table;
    END IF;
  END LOOP;
END $$;
