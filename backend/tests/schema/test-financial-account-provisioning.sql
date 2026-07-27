-- FC-02 canonical account-purpose provisioning contract.
DO $$
DECLARE
 org CONSTANT UUID:='00000000-0000-4000-8000-000000000101'; actor CONSTANT UUID:='00000000-0000-4000-8000-000000000101'; outsider CONSTANT UUID:='00000000-0000-4000-8000-000000000104';
 rule financial_account_purpose_rules; owner_type TEXT; owner_id UUID; result JSONB; replay JSONB; counter INTEGER:=0;
BEGIN
 FOR rule IN SELECT * FROM financial_account_purpose_rules ORDER BY purpose LOOP
  counter:=counter+1; owner_type:=rule.allowed_owner_types[1];
  owner_id:=CASE WHEN owner_type IN ('organization','system') THEN NULL ELSE gen_random_uuid() END;
  result:=provision_financial_account(org,actor,'9'||lpad(counter::TEXT,3,'0')||'.'||upper(substr(md5(rule.purpose),1,6)),
    initcap(replace(rule.purpose,'_',' ')),rule.purpose,'NGN',owner_type,owner_id,DATE '2026-07-27','purpose-provision-'||lpad(counter::TEXT,3,'0'));
  IF result->>'purpose'<>rule.purpose OR result->>'account_class'<>rule.account_class OR result->>'normal_side'<>rule.normal_side
    OR (result->>'is_control')::BOOLEAN<>rule.is_control OR result->>'organization_id'<>org::TEXT THEN
    RAISE EXCEPTION 'purpose % provisioned with invalid canonical facts',rule.purpose;
  END IF;
 END LOOP;
 IF counter<>18 THEN RAISE EXCEPTION 'canonical purpose catalogue is incomplete'; END IF;
 SELECT to_jsonb(fa) INTO result FROM financial_accounts fa WHERE organization_id=org AND provisioning_key='purpose-provision-001';
 replay:=provision_financial_account(org,actor,result->>'code',result->>'name',result->>'purpose',result->>'currency',result->>'owner_type',NULLIF(result->>'owner_id','')::UUID,(result->>'effective_from')::DATE,'purpose-provision-001');
 IF replay->>'id'<>result->>'id' THEN RAISE EXCEPTION 'account provisioning replay created a duplicate'; END IF;
 BEGIN
  PERFORM provision_financial_account(org,actor,result->>'code','Changed account identity',result->>'purpose','NGN',result->>'owner_type',NULLIF(result->>'owner_id','')::UUID,DATE '2026-07-27','purpose-provision-001');
  RAISE EXCEPTION 'changed provisioning replay was accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='changed provisioning replay was accepted' THEN RAISE; END IF; END;
 BEGIN
  PERFORM provision_financial_account(org,outsider,'9999.CROSS','Cross tenant account','operating_cash','NGN','organization',NULL,DATE '2026-07-27','cross-tenant-provision');
  RAISE EXCEPTION 'cross-tenant actor provisioned an account';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='cross-tenant actor provisioned an account' THEN RAISE; END IF; END;
 IF (SELECT count(*) FROM organization_audit_log WHERE action='FINANCIAL_ACCOUNT_PROVISIONED' AND organization_id=org)<>18 THEN RAISE EXCEPTION 'account provisioning audit count is incorrect'; END IF;
END $$;

SET ROLE service_role;
DO $$ BEGIN
 BEGIN INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,is_control)
 VALUES('00000000-0000-4000-8000-000000000101','9999.FORGE','Forged account','asset','debit','NGN','system',TRUE);
 RAISE EXCEPTION 'service role directly inserted a financial account';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='service role directly inserted a financial account' THEN RAISE; END IF; END;
END $$;
RESET ROLE;
