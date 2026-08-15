BEGIN;
DO $$
DECLARE d TEXT;
BEGIN
 SELECT pg_get_functiondef('close_group_project(UUID,UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_PROJECT_RESIDUAL_DISPOSITION_PENDING%' OR d NOT LIKE '%PROJECT_CLOSED%' THEN RAISE EXCEPTION 'GT08B4 closeout invariant missing'; END IF;
END $$;
SELECT 'group project closeout schema tests passed' AS result;
ROLLBACK;
