BEGIN;
DO $$
DECLARE d TEXT;
BEGIN
 SELECT pg_get_functiondef('create_group_project(UUID,UUID,UUID,TEXT,TEXT,TEXT,UUID,UUID,DATE,DATE,JSONB,JSONB,JSONB,TEXT,BIGINT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_PROJECT_PERMISSION_DENIED%' OR d NOT LIKE '%group_project_budget_versions%' THEN RAISE EXCEPTION 'GT08A create invariant missing'; END IF;
 SELECT pg_get_functiondef('approve_group_project(UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_PROJECT_APPROVAL_REQUIRED%' OR d NOT LIKE '%q.proposer_id<>a%' THEN RAISE EXCEPTION 'GT08A approval invariant missing'; END IF;
END $$;
SELECT 'group project foundation schema tests passed' AS result;
ROLLBACK;
