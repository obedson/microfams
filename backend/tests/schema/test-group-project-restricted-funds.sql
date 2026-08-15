BEGIN;
DO $$
DECLARE d TEXT;
BEGIN
 SELECT pg_get_functiondef('enforce_group_project_restricted_disbursement()'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_PROJECT_SPEND_EXCEEDS_APPROVED_BUDGET%' OR d NOT LIKE '%GROUP_PROJECT_RESTRICTED_FUND_RULE_VIOLATION%' OR lower(d) NOT LIKE '%new.budget_id%' OR d NOT LIKE '%restricted_spent%' OR d NOT LIKE '%rule_cap%' THEN RAISE EXCEPTION 'GT08B5 restriction invariant missing'; END IF;
END $$;
SELECT 'group project restricted-fund schema tests passed' AS result;
ROLLBACK;
