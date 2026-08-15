-- INV-13: maker-checker correction for verified post-success investment refund reversals.
SET search_path=public,extensions;

ALTER TABLE investment_refund_obligations DROP CONSTRAINT investment_refund_success_evidence;
ALTER TABLE investment_refund_obligations ADD CONSTRAINT investment_refund_success_evidence
  CHECK((state IN('succeeded','reversed') AND success_journal_id IS NOT NULL AND succeeded_at IS NOT NULL)
    OR (state NOT IN('succeeded','reversed') AND success_journal_id IS NULL AND succeeded_at IS NULL));

CREATE TABLE investment_refund_reversals(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, obligation_id UUID NOT NULL,
  success_journal_id UUID NOT NULL REFERENCES journal_entries(id),
  state TEXT NOT NULL DEFAULT 'proposed' CHECK(state IN('proposed','approved','rejected')),
  provider_name TEXT NOT NULL, provider_environment TEXT NOT NULL CHECK(provider_environment IN('deterministic','sandbox','live')),
  provider_reversal_reference_hash VARCHAR(64) NOT NULL CHECK(provider_reversal_reference_hash~'^[a-f0-9]{64}$'),
  provider_reversal_reference_masked TEXT NOT NULL, provider_event_hash VARCHAR(64) NOT NULL CHECK(provider_event_hash~'^[a-f0-9]{64}$'),
  amount_minor BIGINT NOT NULL CHECK(amount_minor>0), currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
  provider_occurred_at TIMESTAMPTZ NOT NULL, reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 12 AND 500),
  evidence_references JSONB NOT NULL CHECK(jsonb_typeof(evidence_references)='array' AND jsonb_array_length(evidence_references)>0),
  proposed_by UUID NOT NULL REFERENCES users(id), proposed_at TIMESTAMPTZ NOT NULL,
  reviewed_by UUID REFERENCES users(id), review_reason TEXT, reviewed_at TIMESTAMPTZ,
  compensating_journal_id UUID UNIQUE REFERENCES journal_entries(id),
  proposal_idempotency_key TEXT NOT NULL CHECK(length(proposal_idempotency_key) BETWEEN 8 AND 160),
  proposal_request_hash VARCHAR(64) NOT NULL CHECK(proposal_request_hash~'^[a-f0-9]{64}$'), proposal_correlation_id UUID NOT NULL,
  review_idempotency_key TEXT, review_request_hash VARCHAR(64), review_correlation_id UUID,
  FOREIGN KEY(obligation_id,organization_id) REFERENCES investment_refund_obligations(id,organization_id),
  UNIQUE(organization_id,obligation_id), UNIQUE(organization_id,proposal_idempotency_key), UNIQUE(id,organization_id),
  CHECK((state='proposed' AND reviewed_by IS NULL AND compensating_journal_id IS NULL AND review_idempotency_key IS NULL)
    OR (state='approved' AND reviewed_by IS NOT NULL AND reviewed_by<>proposed_by AND review_reason IS NOT NULL
      AND reviewed_at IS NOT NULL AND compensating_journal_id IS NOT NULL AND review_idempotency_key IS NOT NULL
      AND review_request_hash~'^[a-f0-9]{64}$' AND review_correlation_id IS NOT NULL)
    OR (state='rejected' AND reviewed_by IS NOT NULL AND reviewed_by<>proposed_by AND review_reason IS NOT NULL
      AND reviewed_at IS NOT NULL AND compensating_journal_id IS NULL AND review_idempotency_key IS NOT NULL
      AND review_request_hash~'^[a-f0-9]{64}$' AND review_correlation_id IS NOT NULL))
);

CREATE OR REPLACE FUNCTION protect_investment_refund_reversals() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN IF current_setting('microfams.investment_refund_reversal_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'Investment refund reversal evidence is immutable outside the correction engine'; END IF; RETURN COALESCE(NEW,OLD); END $$;
CREATE TRIGGER investment_refund_reversals_engine_only BEFORE INSERT OR UPDATE OR DELETE ON investment_refund_reversals FOR EACH ROW EXECUTE FUNCTION protect_investment_refund_reversals();

CREATE OR REPLACE FUNCTION propose_investment_refund_reversal(
  p_organization UUID,p_actor UUID,p_obligation UUID,p_provider_name TEXT,p_provider_environment TEXT,
  p_provider_reversal_reference TEXT,p_provider_event_hash TEXT,p_amount_minor BIGINT,p_currency TEXT,
  p_occurred_at TIMESTAMPTZ,p_reason TEXT,p_evidence JSONB,p_correlation UUID,p_idempotency_key TEXT,
  p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE o investment_refund_obligations; existing investment_refund_reversals; reversal investment_refund_reversals; h TEXT; ref_hash TEXT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN RAISE EXCEPTION 'Missing financial.investments.service_existing permission'; END IF;
  IF length(COALESCE(trim(p_provider_name),''))<2 OR p_provider_environment NOT IN('deterministic','sandbox','live')
    OR length(COALESCE(trim(p_provider_reversal_reference),'')) NOT BETWEEN 4 AND 200
    OR p_provider_event_hash!~'^[a-f0-9]{64}$' OR p_amount_minor<=0 OR upper(p_currency)!~'^[A-Z]{3}$'
    OR p_occurred_at IS NULL OR length(btrim(COALESCE(p_reason,''))) NOT BETWEEN 12 AND 500
    OR jsonb_typeof(p_evidence)<>'array' OR jsonb_array_length(p_evidence)=0 OR p_correlation IS NULL
    OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 OR p_at IS NULL THEN RAISE EXCEPTION 'Investment refund reversal proposal evidence is invalid'; END IF;
  ref_hash:=encode(digest(convert_to(trim(p_provider_reversal_reference),'UTF8'),'sha256'),'hex');
  h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_obligation,lower(trim(p_provider_name)),p_provider_environment,
    ref_hash,p_provider_event_hash,p_amount_minor,upper(p_currency),p_occurred_at,btrim(p_reason),p_evidence,p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-refund-reversal:'||p_obligation::TEXT,0));
  SELECT * INTO existing FROM investment_refund_reversals WHERE organization_id=p_organization AND proposal_idempotency_key=p_idempotency_key;
  IF existing.id IS NOT NULL THEN IF existing.proposal_request_hash<>h OR existing.obligation_id<>p_obligation THEN RAISE EXCEPTION 'Idempotency key reused with different investment refund reversal facts'; END IF; RETURN jsonb_build_object('reversal',to_jsonb(existing)); END IF;
  SELECT * INTO o FROM investment_refund_obligations WHERE id=p_obligation AND organization_id=p_organization FOR UPDATE;
  IF o.id IS NULL OR o.state<>'succeeded' OR o.success_journal_id IS NULL THEN RAISE EXCEPTION 'Investment refund obligation does not have reversible verified success'; END IF;
  IF lower(trim(p_provider_name))<>o.original_provider OR p_provider_environment<>o.original_environment
    OR p_amount_minor<>o.amount_minor OR upper(p_currency)<>o.currency THEN RAISE EXCEPTION 'Provider reversal evidence does not match the successful refund'; END IF;
  IF p_occurred_at<o.succeeded_at THEN RAISE EXCEPTION 'Provider reversal predates the verified refund success'; END IF;
  IF EXISTS(SELECT 1 FROM investment_refund_reversals WHERE organization_id=p_organization AND obligation_id=p_obligation) THEN RAISE EXCEPTION 'Investment refund already has reversal evidence'; END IF;
  PERFORM set_config('microfams.investment_refund_reversal_engine','on',TRUE);
  INSERT INTO investment_refund_reversals(organization_id,obligation_id,success_journal_id,state,provider_name,
    provider_environment,provider_reversal_reference_hash,provider_reversal_reference_masked,provider_event_hash,
    amount_minor,currency,provider_occurred_at,reason,evidence_references,proposed_by,proposed_at,
    proposal_idempotency_key,proposal_request_hash,proposal_correlation_id)
  VALUES(p_organization,o.id,o.success_journal_id,'proposed',lower(trim(p_provider_name)),p_provider_environment,
    ref_hash,mask_investment_provider_reference(trim(p_provider_reversal_reference)),p_provider_event_hash,p_amount_minor,
    upper(p_currency),p_occurred_at,btrim(p_reason),p_evidence,p_actor,p_at,p_idempotency_key,h,p_correlation) RETURNING * INTO reversal;
  PERFORM set_config('microfams.investment_refund_reversal_engine','off',TRUE);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,'INVESTMENT_REFUND_REVERSAL_PROPOSED','investment_refund_reversal',reversal.id::TEXT,
    jsonb_build_object('obligation_id',o.id,'provider_reference',reversal.provider_reversal_reference_masked,
      'provider_event_hash',p_provider_event_hash,'amount_minor',p_amount_minor,'currency',upper(p_currency)),p_at);
  RETURN jsonb_build_object('reversal',to_jsonb(reversal));
END $$;

CREATE OR REPLACE FUNCTION decide_investment_refund_reversal(
  p_organization UUID,p_actor UUID,p_reversal UUID,p_decision TEXT,p_review_reason TEXT,
  p_correlation UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE reversal investment_refund_reversals; o investment_refund_obligations; h TEXT; journal UUID;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.investments.service_existing') THEN RAISE EXCEPTION 'Missing financial.investments.service_existing permission'; END IF;
  IF p_decision NOT IN('approve','reject') OR length(btrim(COALESCE(p_review_reason,''))) NOT BETWEEN 12 AND 500
    OR p_correlation IS NULL OR length(COALESCE(p_idempotency_key,'')) NOT BETWEEN 8 AND 160 OR p_at IS NULL THEN RAISE EXCEPTION 'Investment refund reversal decision evidence is invalid'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':investment-refund-reversal:'||p_reversal::TEXT,0));
  SELECT * INTO reversal FROM investment_refund_reversals WHERE id=p_reversal AND organization_id=p_organization FOR UPDATE;
  IF reversal.id IS NULL THEN RAISE EXCEPTION 'Investment refund reversal was not found'; END IF;
  h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_reversal,p_decision,btrim(p_review_reason),p_correlation,p_idempotency_key),'UTF8'),'sha256'),'hex');
  IF reversal.state<>'proposed' THEN IF reversal.review_idempotency_key=p_idempotency_key AND reversal.review_request_hash=h THEN RETURN jsonb_build_object('reversal',to_jsonb(reversal)); END IF; RAISE EXCEPTION 'Investment refund reversal is no longer reviewable'; END IF;
  IF reversal.proposed_by=p_actor THEN RAISE EXCEPTION 'Maker cannot approve their own investment refund reversal'; END IF;
  SELECT * INTO o FROM investment_refund_obligations WHERE id=reversal.obligation_id AND organization_id=p_organization FOR UPDATE;
  IF o.state<>'succeeded' OR o.success_journal_id<>reversal.success_journal_id THEN RAISE EXCEPTION 'Investment refund success is no longer reversible'; END IF;
  IF p_decision='approve' THEN
    journal:=reverse_financial_journal(o.success_journal_id,'investment-refund-reversal-'||p_idempotency_key,p_correlation,p_actor,'Restore investment refund payable after verified provider reversal');
    PERFORM set_config('microfams.investment_refund_engine','on',TRUE);
    UPDATE investment_refund_obligations SET state='reversed' WHERE id=o.id AND organization_id=p_organization;
    PERFORM set_config('microfams.investment_refund_engine','off',TRUE);
  END IF;
  PERFORM set_config('microfams.investment_refund_reversal_engine','on',TRUE);
  UPDATE investment_refund_reversals SET state=CASE WHEN p_decision='approve' THEN 'approved' ELSE 'rejected' END,
    reviewed_by=p_actor,review_reason=btrim(p_review_reason),reviewed_at=p_at,compensating_journal_id=journal,
    review_idempotency_key=p_idempotency_key,review_request_hash=h,review_correlation_id=p_correlation
    WHERE id=reversal.id RETURNING * INTO reversal;
  PERFORM set_config('microfams.investment_refund_reversal_engine','off',TRUE);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,p_actor,CASE WHEN p_decision='approve' THEN 'INVESTMENT_REFUND_REVERSAL_APPROVED' ELSE 'INVESTMENT_REFUND_REVERSAL_REJECTED' END,
    'investment_refund_reversal',reversal.id::TEXT,jsonb_build_object('obligation_id',o.id,
      'success_journal_id',o.success_journal_id,'compensating_journal_id',journal,'units_changed',FALSE),p_at);
  RETURN jsonb_build_object('reversal',to_jsonb(reversal),'obligation',(SELECT to_jsonb(x) FROM investment_refund_obligations x WHERE x.id=o.id));
END $$;

ALTER TABLE investment_refund_reversals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON investment_refund_reversals FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON investment_refund_reversals FROM service_role;
GRANT SELECT ON investment_refund_reversals TO service_role;
REVOKE ALL ON FUNCTION propose_investment_refund_reversal(UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,BIGINT,TEXT,TIMESTAMPTZ,TEXT,JSONB,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION decide_investment_refund_reversal(UUID,UUID,UUID,TEXT,TEXT,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION propose_investment_refund_reversal(UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,BIGINT,TEXT,TIMESTAMPTZ,TEXT,JSONB,UUID,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION decide_investment_refund_reversal(UUID,UUID,UUID,TEXT,TEXT,UUID,TEXT,TIMESTAMPTZ) TO service_role;
