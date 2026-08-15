BEGIN;
DO $$
DECLARE d TEXT;
BEGIN
 SELECT pg_get_functiondef('create_group_project_budget_amendment(UUID,UUID,UUID,UUID,UUID,TEXT,BIGINT,JSONB,UUID,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%BUDGET_AMENDMENT_PROPOSED%' OR d NOT LIKE '%version%' THEN RAISE EXCEPTION 'GT08B1 proposal invariant missing'; END IF;
 SELECT pg_get_functiondef('approve_group_project_budget_amendment(UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%state=''superseded''%' OR d NOT LIKE '%BUDGET_AMENDMENT_APPROVED%' THEN RAISE EXCEPTION 'GT08B1 approval invariant missing'; END IF;
END $$;
SELECT 'group project budget amendment schema tests passed' AS result;
ROLLBACK;
