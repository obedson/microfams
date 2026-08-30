BEGIN;
DO $$
BEGIN
  IF (SELECT data_type FROM information_schema.columns WHERE table_schema='public'
      AND table_name='audit_logs' AND column_name='resource_id') <> 'uuid' THEN
    RAISE EXCEPTION 'established audit UUID resource identifier changed';
  END IF;
  IF (SELECT data_type FROM information_schema.columns WHERE table_schema='public'
      AND table_name='audit_logs' AND column_name='resource_key') <> 'text' THEN
    RAISE EXCEPTION 'audit resource key is missing or not text';
  END IF;
  IF (SELECT data_type FROM information_schema.columns WHERE table_schema='public'
      AND table_name='audit_logs' AND column_name='correlation_id') <> 'uuid' THEN
    RAISE EXCEPTION 'audit correlation identifier is missing or not UUID';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='audit_logs' AND column_name IN ('details','created_at')
      AND is_nullable <> 'NO') THEN
    RAISE EXCEPTION 'audit details or timestamp remains nullable';
  END IF;
END $$;
INSERT INTO users(id,email,password,name,role) VALUES
('00000000-0000-4000-8000-000000003951','audit-attribution@example.test',
 'not-a-real-password','Audit Attribution','farmer');
INSERT INTO audit_logs(organization_id,user_id,correlation_id,action,resource_type,resource_key)
VALUES('00000000-0000-4000-8000-000000003951','00000000-0000-4000-8000-000000003951',
 '00000000-0000-4000-8000-000000003952','payment_timeout_job_executed','system','payment_timeout_job');
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM audit_logs WHERE resource_key='payment_timeout_job'
      AND correlation_id='00000000-0000-4000-8000-000000003952'
      AND details='{}'::JSONB) THEN
    RAISE EXCEPTION 'correlated operational audit evidence was not retained';
  END IF;
END $$;
ROLLBACK;
SELECT 'audit observability schema tests passed' AS result;