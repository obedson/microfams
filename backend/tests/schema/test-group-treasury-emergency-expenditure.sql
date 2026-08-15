BEGIN;
DO $$
DECLARE definition TEXT;
BEGIN
  IF to_regclass('public.group_treasury_emergency_policies') IS NULL
    OR to_regclass('public.group_treasury_emergency_expenditures') IS NULL THEN
    RAISE EXCEPTION 'GT06B2 tables are missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='group_treasury_reservations'::regclass
      AND conname='group_treasury_reservations_source_check'
  ) THEN RAISE EXCEPTION 'GT06B2 reservation source constraint is missing'; END IF;
  SELECT pg_get_functiondef('approve_group_treasury_emergency(UUID,UUID,UUID,UUID)'::regprocedure)
    INTO definition;
  IF definition NOT LIKE '%GROUP_TREASURY_EMERGENCY_APPROVER_DUPLICATE%'
    OR definition NOT LIKE '%post_wallet_journal%'
    OR definition NOT LIKE '%emergency_ratification%'
    OR definition NOT LIKE '%group_treasury_emergency%' THEN
    RAISE EXCEPTION 'GT06B2 approval, posting, ratification, or notice evidence is incomplete';
  END IF;
  BEGIN
    INSERT INTO group_treasury_emergency_policies(
      organization_id,group_id,constitution_id,enabled,cap_minor
    ) VALUES (
      '00000000-0000-4000-8000-000000000001',
      '00000000-0000-4000-8000-000000000002',
      '00000000-0000-4000-8000-000000000003',FALSE,100
    );
    RAISE EXCEPTION 'GT06B2 direct write unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%GROUP_TREASURY_EMERGENCY_ENGINE_REQUIRED%' THEN RAISE; END IF;
  END;
END $$;
SELECT 'group treasury emergency expenditure schema tests passed' AS result;
ROLLBACK;
