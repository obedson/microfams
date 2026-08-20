SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID; maker UUID; checker UUID; payer UUID; beneficiary UUID; c UUID; result JSONB; failed BOOLEAN;
BEGIN
 SELECT organization_id,user_id INTO org,maker FROM organization_memberships WHERE role='owner' AND status='active' ORDER BY created_at LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('escrow-payer-'||gen_random_uuid()||'@example.test','test','Escrow Payer','farmer') RETURNING id INTO payer;
 INSERT INTO users(email,password,name,role) VALUES('escrow-beneficiary-'||gen_random_uuid()||'@example.test','test','Escrow Beneficiary','farmer') RETURNING id INTO beneficiary;
 INSERT INTO users(email,password,name,role) VALUES('escrow-checker-'||gen_random_uuid()||'@example.test','test','Escrow Checker','farmer') RETURNING id INTO checker;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at) VALUES(org,checker,'finance_manager',ARRAY['financial.escrow.create'],'active',NOW());
 result:=create_escrow_contract_draft(org,maker,payer,beneficiary,'NGN',500000,'Produce delivery',jsonb_build_array(jsonb_build_object('name','delivery','requiredEvidence',jsonb_build_array('delivery_note'))),jsonb_build_object('mode','single_release'),jsonb_build_array(checker),NOW()+INTERVAL '7 days',NOW()+INTERVAL '14 days','escrow01-create-001',NOW()); c:=(result->>'id')::UUID;
 IF result->>'state'<>'draft' OR c IS NULL THEN RAISE EXCEPTION 'ESC01: draft failed'; END IF;
 failed:=FALSE; BEGIN PERFORM activate_escrow_contract(org,maker,c,'escrow01-maker-activate',NOW()); EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%independent%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'ESC01: maker activated own contract'; END IF;
 result:=activate_escrow_contract(org,checker,c,'escrow01-activate-001',NOW()); IF result->>'state'<>'awaiting_funding' OR result->>'approved_by'<>checker::TEXT THEN RAISE EXCEPTION 'ESC01: activation failed'; END IF;
 IF has_table_privilege('service_role','public.escrow_contracts','UPDATE') THEN RAISE EXCEPTION 'ESC01: contract is mutable'; END IF;
END $$;
ROLLBACK;
SELECT 'escrow contract foundation schema tests passed' AS result;
