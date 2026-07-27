-- FC-06/FC-11 controlled reconciliation resolution and write-off contract.
DO $$
DECLARE
  org CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  maker CONSTANT UUID := '00000000-0000-4000-8000-000000000101';
  checker CONSTANT UUID := '00000000-0000-4000-8000-000000000106';
  outsider CONSTANT UUID := '00000000-0000-4000-8000-000000000104';
  exception UUID; item UUID; debit UUID; credit UUID; journal UUID; request JSONB; replay JSONB; decision JSONB;
BEGIN
  INSERT INTO users(id,email,password,name,role) VALUES(checker,'reconciliation-checker@example.test','not-a-real-password','Reconciliation Checker','farmer') ON CONFLICT(id) DO NOTHING;
  INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at)
  VALUES(org,checker,'finance_manager',ARRAY['financial.reconciliation.approve'],'active',NOW())
  ON CONFLICT(organization_id,user_id) DO UPDATE SET permissions=EXCLUDED.permissions,status='active';
  SELECT id,item_id INTO exception,item FROM reconciliation_exceptions WHERE organization_id=org AND state='investigating' ORDER BY created_at LIMIT 1;
  IF exception IS NULL THEN RAISE EXCEPTION 'investigating reconciliation fixture is missing'; END IF;
  request:=request_reconciliation_exception_resolution(exception,maker,'matched_evidence','Provider evidence requires another review','evidence://reconciliation/rejected-001',NULL,'recon-rejection-0001');
  decision:=decide_reconciliation_exception_resolution((request->>'id')::UUID,checker,FALSE,'Evidence is insufficient for resolution');
  IF decision->>'state'<>'rejected' OR (SELECT state FROM reconciliation_exceptions WHERE id=exception)<>'investigating'
    OR (SELECT state FROM reconciliation_items WHERE id=item)<>'investigating' THEN
    RAISE EXCEPTION 'rejected resolution changed the investigated exception';
  END IF;
  SELECT id INTO debit FROM financial_accounts WHERE organization_id=org AND code='1100.CLEARING';
  SELECT id INTO credit FROM financial_accounts WHERE organization_id=org AND code='2100.WALLET';
  UPDATE accounting_periods SET status='open',closed_at=NULL,closed_by=NULL WHERE organization_id=org AND DATE '2026-07-19' BETWEEN starts_on AND ends_on;
  journal:=post_financial_journal(org,'NGN',DATE '2026-07-19','reconciliation.writeoff',exception::TEXT,
    'recon-writeoff-journal-0001',repeat('e',64),'00000000-0000-4000-8000-000000009106','Approved reconciliation write-off evidence',maker,
    jsonb_build_array(jsonb_build_object('account_id',debit,'line_number',1,'side','debit','amount_minor',100),jsonb_build_object('account_id',credit,'line_number',2,'side','credit','amount_minor',100)));
  BEGIN
    PERFORM request_reconciliation_exception_resolution(exception,maker,'writeoff','Write off verified provider variance','evidence://reconciliation/schema-001',NULL,'recon-resolution-0001');
    RAISE EXCEPTION 'write-off without journal was accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='write-off without journal was accepted' THEN RAISE; END IF; END;
  request:=request_reconciliation_exception_resolution(exception,maker,'writeoff','Write off verified provider variance','evidence://reconciliation/schema-001',journal,'recon-resolution-0001');
  replay:=request_reconciliation_exception_resolution(exception,maker,'writeoff','Write off verified provider variance','evidence://reconciliation/schema-001',journal,'recon-resolution-0001');
  IF request->>'id'<>replay->>'id' OR request->>'state'<>'pending' OR request->>'approval_request_id' IS NULL THEN RAISE EXCEPTION 'resolution request was not atomic and idempotent'; END IF;
  BEGIN
    PERFORM request_reconciliation_exception_resolution(exception,maker,'writeoff','Changed write-off reason is forbidden','evidence://reconciliation/schema-001',journal,'recon-resolution-0001');
    RAISE EXCEPTION 'changed resolution replay was accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='changed resolution replay was accepted' THEN RAISE; END IF; END;
  BEGIN
    PERFORM decide_reconciliation_exception_resolution((request->>'id')::UUID,maker,TRUE,'Maker attempted self approval');
    RAISE EXCEPTION 'maker approved their own resolution';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='maker approved their own resolution' THEN RAISE; END IF; END;
  BEGIN
    PERFORM decide_reconciliation_exception_resolution((request->>'id')::UUID,outsider,TRUE,'Outsider attempted cross tenant approval');
    RAISE EXCEPTION 'cross-tenant checker approved resolution';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='cross-tenant checker approved resolution' THEN RAISE; END IF; END;
  decision:=decide_reconciliation_exception_resolution((request->>'id')::UUID,checker,TRUE,'Independent checker verified evidence');
  replay:=decide_reconciliation_exception_resolution((request->>'id')::UUID,checker,TRUE,'Independent checker verified evidence');
  IF decision->>'state'<>'approved' OR replay->>'id'<>decision->>'id'
    OR (SELECT state FROM reconciliation_exceptions WHERE id=exception)<>'resolved'
    OR (SELECT state FROM reconciliation_items WHERE id=item)<>'resolved'
    OR (SELECT compensating_journal_entry_id FROM reconciliation_exceptions WHERE id=exception)<>journal
    OR (SELECT state FROM financial_approval_requests WHERE id=(request->>'approval_request_id')::UUID)<>'approved' THEN
    RAISE EXCEPTION 'approved reconciliation resolution was not applied atomically';
  END IF;
  IF (SELECT count(*) FROM organization_audit_log WHERE resource_type='reconciliation_resolution_request' AND resource_id=request->>'id')<>2 THEN
    RAISE EXCEPTION 'resolution request and decision audits are incomplete';
  END IF;
END $$;

SET ROLE service_role;
DO $$ BEGIN
 BEGIN UPDATE reconciliation_resolution_requests SET decision_reason='forged decision'; RAISE EXCEPTION 'service role directly changed resolution evidence';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='service role directly changed resolution evidence' THEN RAISE; END IF; END;
END $$;
RESET ROLE;
