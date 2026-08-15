-- INV-09/10/11 database contract: durable submission, recovery, callbacks, and verified success posting.
SET search_path=public,extensions;
BEGIN;
DO $$
DECLARE org UUID; maker UUID; checker UUID; product UUID; intent UUID; settlement UUID; settlement_journal UUID; plan UUID; obligation UUID; attempt UUID; result JSONB; replay JSONB; facts JSONB; failed BOOLEAN; journal_count BIGINT; result_hash TEXT;
BEGIN
 SELECT organization_id,user_id INTO org,maker FROM organization_memberships WHERE role='owner' AND status='active' ORDER BY created_at LIMIT 1;
 INSERT INTO users(email,password,name,role) VALUES('inv09-checker-'||gen_random_uuid()||'@example.test','test','INV-09 Checker','farmer') RETURNING id INTO checker;
 INSERT INTO organization_memberships(organization_id,user_id,role,permissions,status,joined_at) VALUES(org,checker,'finance_manager',ARRAY['financial.investments.configure','financial.investments.service_existing'],'active',NOW());
 facts:=jsonb_build_object('issuerName','Farm Project Issuer','operatorName','Licensed Investment Operator','underlyingReference','farm-project-inv09','fundingTargetMinor',100000,'minimumSubscriptionMinor',100000,'maximumSubscriptionMinor',200000,'offerOpensAt','2026-09-01T00:00:00Z','offerClosesAt','2026-09-30T00:00:00Z','unitMethod','fixed_unit_price','unitPriceMinor',100000,'oversubscriptionPolicy','pro_rata','fees','[]'::JSONB,'expectedReturnDisclosure','Expected returns are estimates and are not guaranteed.','lossAllocationRule',jsonb_build_object('method','pro_rata_units'),'reportingSchedule',jsonb_build_object('frequency','quarterly'),'maturityAt','2027-09-30T00:00:00Z','exitRules',jsonb_build_object('earlyExit',FALSE),'jurisdictionEligibility',jsonb_build_object('countries',jsonb_build_array('NG'),'investorTypes',jsonb_build_array('individual')),'riskDisclosureVersion','INV-09.1','riskDisclosureHash',repeat('c',64),'conflictsDisclosure','The operator discloses all related-party interests.');
 result:=create_investment_product_draft(org,maker,'INV.FARM.09','INV-09 farm units','NGN',facts,'inv09-product-create','2026-08-14T06:00:00Z'); product:=(result->'product'->>'id')::UUID;
 PERFORM submit_investment_product(org,maker,product,1,'inv09-product-submit','2026-08-14T06:01:00Z');
 PERFORM approve_investment_product(org,checker,product,1,'inv09-product-approve','2026-08-14T06:02:00Z');
 PERFORM open_investment_product_offer(org,checker,product,1,'inv09-product-open','2026-09-15T11:59:00Z');
 intent:=(create_investment_subscription_intent(org,maker,product,200000,'NG','individual','INV-09.1',repeat('c',64),'00000000-0000-4000-8000-000000000901','inv09-subscribe-001','2026-09-15T12:00:00Z')->'subscription'->>'id')::UUID;
 SELECT post_wallet_journal(org,'investment.test.custody','inv09-settlement-source','INV-09 settlement',jsonb_build_array(jsonb_build_object('account_id',ensure_wallet_system_account(org,'PAYMENT.BANK_CASH','Test bank cash','asset','debit'),'line_number',1,'side','debit','amount_minor',200000,'memo','INV-09 cash'),jsonb_build_object('account_id',ensure_wallet_system_account(org,'PAYMENT.CLEARING.INV09','Test clearing','asset','debit'),'line_number',2,'side','credit','amount_minor',200000,'memo','INV-09 clearing'))) INTO settlement_journal;
 PERFORM set_config('microfams.payment_engine','on',TRUE);
 INSERT INTO settlements(organization_id,provider_name,provider_environment,provider_reference,currency,gross_amount_minor,fee_amount_minor,net_amount_minor,source_hash,state,settled_at,journal_entry_id) VALUES(org,'deterministic','deterministic','inv09-provider-payment-001','NGN',200000,0,200000,encode(digest(convert_to('inv09-provider-payment-001','UTF8'),'sha256'),'hex'),'posted','2026-09-15T12:03:00Z',settlement_journal) RETURNING id INTO settlement;
 PERFORM settle_investment_subscription(org,checker,intent,settlement,'00000000-0000-4000-8000-000000000902','inv09-settle-001','2026-09-15T12:05:00Z');
 result:=create_investment_allocation_plan(org,maker,product,'2026-09-30T00:01:00Z','00000000-0000-4000-8000-000000000903','inv09-plan-create-001','2026-10-01T00:00:00Z'); plan:=(result->'plan'->>'id')::UUID;
 PERFORM approve_investment_allocation_plan(org,checker,plan,'inv09-plan-approve-001','2026-10-02T00:02:00Z');
 IF NOT EXISTS(SELECT 1 FROM accounting_periods WHERE organization_id=org AND status='open' AND DATE '2026-10-02' BETWEEN starts_on AND ends_on) THEN INSERT INTO accounting_periods(organization_id,name,starts_on,ends_on,status) VALUES(org,'INV-09 recognition period','2026-01-01','2026-12-31','open'); END IF;
 result:=recognize_investment_refund_obligations(org,maker,plan,'00000000-0000-4000-8000-000000000904','inv09-refund-recognize-001','2026-10-02T00:03:00Z');
 SELECT id INTO obligation FROM investment_refund_obligations WHERE organization_id=org AND plan_id=plan;
 SELECT count(*) INTO journal_count FROM journal_entries WHERE organization_id=org;
 BEGIN
  result:=begin_investment_refund_submission(org,maker,obligation,'00000000-0000-4000-8000-000000000905','inv09-submit-timeout-001','2026-10-02T00:03:30Z'); attempt:=(result->'attempt'->>'id')::UUID;
  result_hash:=encode(digest(convert_to('inv09-provider-timeout-001','UTF8'),'sha256'),'hex');
  result:=complete_investment_refund_submission(org,maker,attempt,'unknown',NULL,NULL,NULL,NULL,'provider_response_ambiguous','Provider response timed out.',result_hash,'2026-10-02T00:03:45Z');
  IF result->'attempt'->>'state'<>'unknown' OR result->'obligation'->>'state'<>'unknown' OR result->'attempt'->>'reported_amount_minor' IS NOT NULL OR result->'attempt'->>'reported_currency' IS NOT NULL THEN RAISE EXCEPTION 'INV09: timeout evidence required fabricated provider money'; END IF;
  IF (SELECT count(*) FROM journal_entries WHERE organization_id=org)<>journal_count THEN RAISE EXCEPTION 'INV09: unknown provider result posted premature cash movement'; END IF;
  RAISE EXCEPTION 'INV09_UNKNOWN_ROLLBACK';
 EXCEPTION WHEN SQLSTATE 'P0001' THEN
  IF SQLERRM<>'INV09_UNKNOWN_ROLLBACK' THEN RAISE; END IF;
 END;
 result:=begin_investment_refund_submission(org,maker,obligation,'00000000-0000-4000-8000-000000000905','inv09-submit-001','2026-10-02T00:04:00Z'); attempt:=(result->'attempt'->>'id')::UUID;
 IF (result->>'replayed')::BOOLEAN OR result->'attempt'->>'state'<>'prepared' OR result->>'provider_payment_reference'<>'inv09-provider-payment-001' OR (result->'obligation'->>'amount_minor')::BIGINT<>100000 THEN RAISE EXCEPTION 'INV09: prepared submission did not pin exact original-provider facts'; END IF;
 result_hash:=encode(digest(convert_to('inv09-provider-result-001','UTF8'),'sha256'),'hex');
 result:=complete_investment_refund_submission(org,maker,attempt,'processing','succeeded','det-refund-sensitive-987654321',100000,'NGN',NULL,NULL,result_hash,'2026-10-02T00:05:00Z');
 IF result->'attempt'->>'state'<>'processing' OR result->'obligation'->>'state'<>'processing' OR result->'attempt'->>'provider_reported_state'<>'succeeded' THEN RAISE EXCEPTION 'INV09: synchronous provider success was treated as final or not recorded'; END IF;
 IF (SELECT count(*) FROM journal_entries WHERE organization_id=org)<>journal_count THEN RAISE EXCEPTION 'INV09: provider submission posted premature cash movement'; END IF;
 IF (SELECT provider_reference_masked FROM investment_refund_attempts WHERE id=attempt)='det-refund-sensitive-987654321' OR (SELECT provider_reference_hash FROM investment_refund_attempts WHERE id=attempt) IS NULL THEN RAISE EXCEPTION 'INV09: raw provider reference was stored'; END IF;
 result:=prepare_investment_refund_recovery(org,maker,obligation);
 IF (result->'attempt'->>'id')::UUID<>attempt OR result->>'provider_payment_reference'<>'inv09-provider-payment-001' THEN RAISE EXCEPTION 'INV10: recovery did not use the durable original-provider route'; END IF;
 BEGIN
  result_hash:=encode(digest(convert_to('inv10-provider-success-001','UTF8'),'sha256'),'hex');
  result:=complete_investment_refund_recovery(org,maker,attempt,'succeeded','succeeded','det-refund-sensitive-987654321',100000,'NGN',NULL,NULL,result_hash,'2026-10-02T00:06:00Z');
  IF result->'attempt'->>'state'<>'succeeded' OR result->'obligation'->>'success_journal_id' IS NULL THEN RAISE EXCEPTION 'INV10: verified provider success was not finalized'; END IF;
  IF (SELECT count(*) FROM journal_entries WHERE organization_id=org)<>journal_count+1 THEN RAISE EXCEPTION 'INV10: verified success did not post exactly one journal'; END IF;
  replay:=complete_investment_refund_recovery(org,maker,attempt,'succeeded','succeeded','det-refund-sensitive-987654321',100000,'NGN',NULL,NULL,result_hash,'2026-10-02T00:07:00Z');
  IF (SELECT count(*) FROM investment_refund_recovery_events WHERE attempt_id=attempt)<>1 THEN RAISE EXCEPTION 'INV10: recovery replay duplicated evidence'; END IF;
  RAISE EXCEPTION 'INV10_SUCCESS_ROLLBACK';
 EXCEPTION WHEN SQLSTATE 'P0001' THEN
  IF SQLERRM<>'INV10_SUCCESS_ROLLBACK' THEN RAISE; END IF;
 END;
 result:=apply_investment_refund_callback('deterministic','deterministic',attempt,'inv11-event-failed',
   'refund.failed',encode(digest(convert_to('inv11-failed-body','UTF8'),'sha256'),'hex'),'failed','failed',
   'det-refund-sensitive-987654321',100000,'NGN','2026-10-02T00:08:00Z','provider_failed','Provider rejected the refund.','2026-10-02T00:08:01Z');
 IF result->'obligation'->>'state'<>'failed' OR (SELECT count(*) FROM journal_entries WHERE organization_id=org)<>journal_count THEN RAISE EXCEPTION 'INV11: failed callback moved cash or lost the liability'; END IF;
 result:=apply_investment_refund_callback('deterministic','deterministic',attempt,'inv11-event-success',
   'refund.processed',encode(digest(convert_to('inv11-success-body','UTF8'),'sha256'),'hex'),'succeeded','succeeded',
   'det-refund-sensitive-987654321',100000,'NGN','2026-10-02T00:09:00Z',NULL,NULL,'2026-10-02T00:09:01Z');
 IF result->'obligation'->>'state'<>'succeeded' OR result->'obligation'->>'success_journal_id' IS NULL THEN RAISE EXCEPTION 'INV11: late callback success was not finalized'; END IF;
 IF (SELECT count(*) FROM journal_entries WHERE organization_id=org)<>journal_count+1 THEN RAISE EXCEPTION 'INV11: callback success did not post exactly one journal'; END IF;
 IF EXISTS(SELECT 1 FROM journal_entries j LEFT JOIN journal_lines l ON l.journal_entry_id=j.id WHERE j.id=(result->'obligation'->>'success_journal_id')::UUID GROUP BY j.id HAVING sum(CASE WHEN l.side='debit' THEN l.amount_minor ELSE 0 END)<>100000 OR sum(CASE WHEN l.side='credit' THEN l.amount_minor ELSE 0 END)<>100000) THEN RAISE EXCEPTION 'INV11: callback success journal is not exact and balanced'; END IF;
 replay:=apply_investment_refund_callback('deterministic','deterministic',attempt,'inv11-event-success',
   'refund.processed',encode(digest(convert_to('inv11-success-body','UTF8'),'sha256'),'hex'),'succeeded','succeeded',
   'det-refund-sensitive-987654321',100000,'NGN','2026-10-02T00:09:00Z',NULL,NULL,'2026-10-02T00:10:00Z');
 IF NOT (replay->>'duplicate')::BOOLEAN OR (SELECT count(*) FROM journal_entries WHERE organization_id=org)<>journal_count+1 OR (SELECT count(*) FROM investment_refund_callback_events WHERE attempt_id=attempt)<>2 THEN RAISE EXCEPTION 'INV11: callback replay duplicated journal or evidence'; END IF;
 failed:=FALSE; BEGIN
  PERFORM apply_investment_refund_callback('deterministic','deterministic',attempt,'inv11-event-success',
   'refund.processed',encode(digest(convert_to('inv11-changed-body','UTF8'),'sha256'),'hex'),'succeeded','succeeded',
   'det-refund-sensitive-987654321',100000,'NGN','2026-10-02T00:09:00Z',NULL,NULL,'2026-10-02T00:10:01Z');
 EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%changed bytes%' THEN failed:=TRUE; END IF; END;
 IF NOT failed THEN RAISE EXCEPTION 'INV11: provider event identity accepted changed bytes'; END IF;
 IF NOT EXISTS(SELECT 1 FROM investment_refund_callback_events WHERE attempt_id=attempt AND signature_verified) THEN RAISE EXCEPTION 'INV11: verified callback evidence was not recorded'; END IF;
 failed:=FALSE; BEGIN UPDATE investment_refund_callback_events SET state='failed' WHERE attempt_id=attempt; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%immutable%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV11: callback evidence was mutable'; END IF;
 failed:=FALSE; BEGIN PERFORM apply_investment_refund_callback('paystack','sandbox',attempt,'inv11-cross-provider','refund.processed',encode(digest(convert_to('inv11-cross-provider','UTF8'),'sha256'),'hex'),'succeeded','succeeded','ref',100000,'NGN',NULL,NULL,NULL,NOW()); EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%attempt was not found%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV11: callback crossed the original provider boundary'; END IF;
 IF EXISTS(SELECT 1 FROM investment_refund_callback_events WHERE attempt_id=attempt AND provider_reference_masked='det-refund-sensitive-987654321') THEN RAISE EXCEPTION 'INV11: raw provider callback reference was retained'; END IF;
 replay:=begin_investment_refund_submission(org,maker,obligation,'00000000-0000-4000-8000-000000000905','inv09-submit-001','2026-10-03T00:00:00Z');
 IF NOT (replay->>'replayed')::BOOLEAN OR (replay->'attempt'->>'id')::UUID<>attempt OR (SELECT count(*) FROM investment_refund_attempts WHERE obligation_id=obligation)<>1 THEN RAISE EXCEPTION 'INV09: idempotent replay duplicated provider attempt evidence'; END IF;
 failed:=FALSE; BEGIN PERFORM begin_investment_refund_submission(org,maker,obligation,'00000000-0000-4000-8000-000000000906','inv09-submit-001','2026-10-03T00:01:00Z'); EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%different investment refund submission facts%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV09: changed replay facts were accepted'; END IF;
 failed:=FALSE; BEGIN PERFORM begin_investment_refund_submission(checker,maker,obligation,'00000000-0000-4000-8000-000000000907','inv09-cross-tenant','2026-10-03T00:02:00Z'); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END; IF NOT failed THEN RAISE EXCEPTION 'INV09: cross-tenant submission was accepted'; END IF;
 failed:=FALSE; BEGIN UPDATE investment_refund_attempts SET state='failed' WHERE id=attempt; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%immutable%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV09: provider attempt evidence was mutable'; END IF;
 IF NOT EXISTS(SELECT 1 FROM organization_audit_log WHERE organization_id=org AND action='INVESTMENT_REFUND_SUBMISSION_RECORDED' AND resource_id=obligation::TEXT AND after_value->>'provider_reference' LIKE 'det-%4321') THEN RAISE EXCEPTION 'INV09: masked provider submission audit evidence is missing'; END IF;
 SELECT count(*) INTO journal_count FROM journal_entries WHERE organization_id=org;
 result:=run_investment_refund_reconciliation(org,maker,'deterministic','deterministic',repeat('d',64),
   'inv12-reconciliation-001','2026-10-01T00:00:00Z','2026-10-04T00:00:00Z',jsonb_build_array(
     jsonb_build_object('internalReference','investment-refund-'||attempt::TEXT,'providerReference','det-refund-sensitive-987654321','status','succeeded','amountMinor',100000,'currency','NGN','occurredAt','2026-10-02T00:09:00Z'),
     jsonb_build_object('internalReference','investment-refund-'||attempt::TEXT,'providerReference','det-refund-sensitive-987654321','status','succeeded','amountMinor',100000,'currency','NGN','occurredAt','2026-10-02T00:09:01Z'),
     jsonb_build_object('internalReference','investment-refund-00000000-0000-4000-8000-000000000999','providerReference','provider-only-ref','status','succeeded','amountMinor',25000,'currency','NGN','occurredAt','2026-10-02T00:10:00Z')
   ),'2026-10-04T00:01:00Z');
 IF (result->'run'->>'matched_count')::INTEGER<>1 OR (result->'run'->>'exception_count')::INTEGER<>2
   OR NOT EXISTS(SELECT 1 FROM investment_refund_reconciliation_items WHERE run_id=(result->'run'->>'id')::UUID AND classification='duplicate_provider')
   OR NOT EXISTS(SELECT 1 FROM investment_refund_reconciliation_items WHERE run_id=(result->'run'->>'id')::UUID AND classification='missing_local') THEN RAISE EXCEPTION 'INV12: provider comparison classifications are incomplete'; END IF;
 IF (SELECT count(*) FROM investment_refund_reconciliation_exceptions WHERE run_id=(result->'run'->>'id')::UUID)<>2 THEN RAISE EXCEPTION 'INV12: durable exceptions were not created'; END IF;
 IF (SELECT state FROM investment_refund_attempts WHERE id=attempt)<>'succeeded'
   OR (SELECT state FROM investment_refund_obligations WHERE id=obligation)<>'succeeded'
   OR (SELECT count(*) FROM journal_entries WHERE organization_id=org)<>journal_count THEN RAISE EXCEPTION 'INV12: reconciliation mutated financial state'; END IF;
 replay:=run_investment_refund_reconciliation(org,maker,'deterministic','deterministic',repeat('d',64),
   'inv12-reconciliation-001','2026-10-01T00:00:00Z','2026-10-04T00:00:00Z',jsonb_build_array(),'2026-10-04T00:02:00Z');
 IF NOT (replay->>'duplicate')::BOOLEAN OR (replay->'run'->>'id')::UUID<>(result->'run'->>'id')::UUID THEN RAISE EXCEPTION 'INV12: idempotent replay duplicated the reconciliation run'; END IF;
 replay:=run_investment_refund_reconciliation(org,maker,'deterministic','deterministic',repeat('e',64),
   'inv12-reconciliation-002','2026-10-01T00:00:00Z','2026-10-04T00:00:00Z',jsonb_build_array(),'2026-10-04T00:03:00Z');
 IF NOT EXISTS(SELECT 1 FROM investment_refund_reconciliation_items WHERE run_id=(replay->'run'->>'id')::UUID AND classification='missing_provider' AND attempt_id=attempt) THEN RAISE EXCEPTION 'INV12: missing provider evidence was not classified'; END IF;
 failed:=FALSE; BEGIN UPDATE investment_refund_reconciliation_exceptions SET state='closed' WHERE run_id=(result->'run'->>'id')::UUID; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%immutable%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV12: reconciliation exception evidence was mutable'; END IF;
 IF EXISTS(SELECT 1 FROM investment_refund_reconciliation_items WHERE run_id=(result->'run'->>'id')::UUID AND provider_reference_masked='det-refund-sensitive-987654321') THEN RAISE EXCEPTION 'INV12: raw provider reference was retained'; END IF;
 IF NOT EXISTS(SELECT 1 FROM organization_audit_log WHERE organization_id=org AND action='INVESTMENT_REFUND_RECONCILIATION_RECORDED' AND after_value->>'financial_correction'='none') THEN RAISE EXCEPTION 'INV12: no-correction audit evidence is missing'; END IF;
 result:=propose_investment_refund_reversal(org,maker,obligation,'deterministic','deterministic','det-refund-reversal-001',repeat('f',64),100000,'NGN','2026-10-05T00:00:00Z','Verified provider reversal restored the refund liability.',jsonb_build_array('provider:event:reversal-001'),'00000000-0000-4000-8000-000000000908','inv13-reversal-proposal-001','2026-10-05T00:01:00Z');
 IF (result->'reversal'->>'state')<>'proposed' OR (result->'reversal'->>'success_journal_id')<>(SELECT success_journal_id::TEXT FROM investment_refund_obligations WHERE id=obligation) THEN RAISE EXCEPTION 'INV13: reversal proposal did not preserve success evidence'; END IF;
 failed:=FALSE; BEGIN result:=decide_investment_refund_reversal(org,maker,(result->'reversal'->>'id')::UUID,'approve','Maker cannot approve own reversal.','00000000-0000-4000-8000-000000000909','inv13-reversal-maker-001','2026-10-05T00:02:00Z'); EXCEPTION WHEN OTHERS THEN failed:=TRUE; END; IF NOT failed THEN RAISE EXCEPTION 'INV13: maker approved own reversal'; END IF;
 result:=decide_investment_refund_reversal(org,checker,(result->'reversal'->>'id')::UUID,'approve','Independent checker verified provider reversal evidence.','00000000-0000-4000-8000-000000000909','inv13-reversal-decision-001','2026-10-05T00:03:00Z');
 IF (result->'reversal'->>'state')<>'approved' OR (result->'reversal'->>'compensating_journal_id') IS NULL OR (result->'obligation'->>'state')<>'reversed' THEN RAISE EXCEPTION 'INV13: approved reversal did not restore payable state'; END IF;
 IF (SELECT count(*) FROM journal_entries WHERE organization_id=org)<>journal_count+1 THEN RAISE EXCEPTION 'INV13: reversal did not post exactly one compensating journal'; END IF;
 IF (SELECT count(*) FROM journal_entries WHERE id=(result->'reversal'->>'success_journal_id')::UUID)<>1 OR (SELECT state FROM investment_refund_obligations WHERE id=obligation)<>'reversed' THEN RAISE EXCEPTION 'INV13: original success evidence was not preserved'; END IF;
 replay:=decide_investment_refund_reversal(org,checker,(result->'reversal'->>'id')::UUID,'approve','Independent checker verified provider reversal evidence.','00000000-0000-4000-8000-000000000909','inv13-reversal-decision-001','2026-10-05T00:04:00Z');
 IF NOT (replay->'reversal'->>'id')::UUID=(result->'reversal'->>'id')::UUID OR (SELECT count(*) FROM journal_entries WHERE organization_id=org)<>journal_count+1 THEN RAISE EXCEPTION 'INV13: reversal replay duplicated correction'; END IF;
 failed:=FALSE; BEGIN UPDATE investment_refund_reversals SET state='rejected' WHERE organization_id=org; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE '%immutable%' THEN failed:=TRUE; END IF; END; IF NOT failed THEN RAISE EXCEPTION 'INV13: reversal evidence was mutable'; END IF;
END $$;
ROLLBACK;
SELECT 'investment refund provider submission, recovery, callback, reconciliation, and reversal schema tests passed' AS result;
