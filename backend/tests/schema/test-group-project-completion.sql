BEGIN;
DO $$
DECLARE d TEXT;
BEGIN
 SELECT pg_get_functiondef('complete_group_project(UUID,UUID,UUID,UUID,JSONB,JSONB,JSONB,JSONB,JSONB,UUID,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_PROJECT_RECONCILIATION_INCOMPLETE%' OR d NOT LIKE '%PROJECT_COMPLETED%' THEN RAISE EXCEPTION 'GT08B3 completion invariant missing'; END IF;
END $$;
SELECT 'group project completion schema tests passed' AS result;
ROLLBACK;
