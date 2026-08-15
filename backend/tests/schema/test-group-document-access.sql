BEGIN;
DO $$
DECLARE d TEXT;
BEGIN
 IF to_regclass('public.group_document_access_events') IS NULL THEN RAISE EXCEPTION 'GT10B access event table missing'; END IF;
 SELECT pg_get_functiondef('authorize_group_document_download(UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ,TIMESTAMPTZ)'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_DOCUMENT_ACCESS_DENIED%' OR d NOT LIKE '%groups.documents.manage%' OR d NOT LIKE '%group_members%' OR d NOT LIKE '%allowed_permissions%' THEN RAISE EXCEPTION 'GT10B access policy invariant missing'; END IF;
 SELECT pg_get_functiondef('protect_group_document_access_event()'::regprocedure) INTO d;
 IF d NOT LIKE '%GROUP_DOCUMENT_ACCESS_EVIDENCE_IMMUTABLE%' THEN RAISE EXCEPTION 'GT10B access evidence invariant missing'; END IF;
END $$;
SELECT 'group document access schema tests passed' AS result;
ROLLBACK;
