UPDATE accounting_periods
SET status = 'open', closed_at = NULL, closed_by = NULL
WHERE organization_id = '00000000-0000-4000-8000-000000000101'
  AND DATE '2026-07-19' BETWEEN starts_on AND ends_on;

INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
VALUES (
  '00000000-0000-4000-8000-000000000101',
  '00000000-0000-4000-8000-000000000102',
  'member', 'active', NOW()
)
ON CONFLICT (organization_id, user_id) DO UPDATE SET status = 'active';

INSERT INTO user_wallets(user_id, organization_id, balance)
VALUES (
  '00000000-0000-4000-8000-000000000102',
  '00000000-0000-4000-8000-000000000101',
  25.50
);

DO $$
DECLARE
  ready_run wallet_ledger_migration_runs;
  blocked_run wallet_ledger_migration_runs;
BEGIN
  ready_run := audit_wallet_ledger_cutover(
    '00000000-0000-4000-8000-000000000101',
    '00000000-0000-4000-8000-000000000101'
  );
  IF ready_run.status <> 'ready' OR ready_run.wallet_count <> 1 OR ready_run.group_count <> 1
    OR ready_run.wallet_total_minor <> 2550 OR ready_run.group_total_minor <> 150000
    OR ready_run.anomaly_count <> 0 OR ready_run.control_hash !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'wallet cutover readiness controls are incorrect: %', to_jsonb(ready_run);
  END IF;

  UPDATE accounting_periods SET status = 'closed', closed_at = NOW()
  WHERE organization_id = '00000000-0000-4000-8000-000000000102';
  blocked_run := audit_wallet_ledger_cutover(
    '00000000-0000-4000-8000-000000000102',
    '00000000-0000-4000-8000-000000000102'
  );
  IF blocked_run.status <> 'blocked' OR NOT EXISTS (
    SELECT 1 FROM wallet_ledger_migration_anomalies
    WHERE run_id = blocked_run.id AND code = 'accounting_period_missing'
  ) THEN
    RAISE EXCEPTION 'missing accounting period did not block cutover readiness';
  END IF;

  BEGIN
    INSERT INTO user_wallets(user_id, organization_id)
    VALUES (
      '00000000-0000-4000-8000-000000000102',
      '00000000-0000-4000-8000-000000000101'
    );
    RAISE EXCEPTION 'duplicate tenant wallet was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END $$;

GRANT SELECT ON wallet_ledger_migration_runs, wallet_ledger_migration_anomalies TO authenticated;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000101', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM wallet_ledger_migration_runs) <> 1 THEN
    RAISE EXCEPTION 'tenant cannot read its wallet migration audit';
  END IF;
END $$;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000103', FALSE);
DO $$ BEGIN
  IF (SELECT count(*) FROM wallet_ledger_migration_runs) <> 0
    OR (SELECT count(*) FROM wallet_ledger_migration_anomalies) <> 0 THEN
    RAISE EXCEPTION 'wallet migration audit leaked across tenants';
  END IF;
END $$;
RESET ROLE;
