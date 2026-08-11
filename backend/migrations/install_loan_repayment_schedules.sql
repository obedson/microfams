-- CRD-04: immutable contractual repayment schedules generated from accepted
-- offers, with exact aggregate reconciliation and disbursement-relative dates.

SET search_path = public, extensions;

ALTER TABLE loan_application_events DROP CONSTRAINT loan_application_events_action_check;
ALTER TABLE loan_application_events ADD CONSTRAINT loan_application_events_action_check CHECK (action IN (
  'application_created','application_submitted','adverse_review_requested',
  'adverse_review_upheld','adverse_review_reopened','application_withdrawn',
  'credit_review_declined','offer_issued','offer_revised','offer_accepted','offer_expired',
  'repayment_schedule_generated'
));

CREATE OR REPLACE FUNCTION loan_repayment_frequency_days(p_frequency TEXT,p_tenor_days INTEGER)
RETURNS INTEGER LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE p_frequency
    WHEN 'weekly' THEN 7
    WHEN 'fortnightly' THEN 14
    WHEN 'monthly' THEN 30
    WHEN 'quarterly' THEN 91
    WHEN 'bullet' THEN p_tenor_days
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION calculate_loan_schedule_upfront_fees(p_principal_minor BIGINT,p_fees JSONB)
RETURNS BIGINT LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT COALESCE(SUM(CASE
    WHEN fee->>'calculation' = 'fixed' THEN (fee->>'amountMinor')::BIGINT
    ELSE CEIL(p_principal_minor::NUMERIC*(fee->>'rateBasisPoints')::NUMERIC/10000)::BIGINT
  END),0)::BIGINT
  FROM jsonb_array_elements(p_fees) fee
  WHERE NOT (fee->>'capitalized')::BOOLEAN
    AND fee->>'timing' IN ('application','disbursement');
$$;

ALTER TABLE loan_offers ADD CONSTRAINT loan_offers_application_identity
  UNIQUE (id,application_id,organization_id);

CREATE TABLE loan_repayment_schedules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  application_id UUID NOT NULL,
  offer_id UUID NOT NULL,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
  state TEXT NOT NULL DEFAULT 'contractual' CHECK (state = 'contractual'),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  algorithm_version TEXT NOT NULL CHECK (length(btrim(algorithm_version)) BETWEEN 1 AND 80),
  due_date_basis TEXT NOT NULL CHECK (due_date_basis = 'days_after_confirmed_disbursement'),
  repayment_frequency TEXT NOT NULL CHECK (
    repayment_frequency IN ('weekly','fortnightly','monthly','quarterly','bullet')
  ),
  frequency_days INTEGER NOT NULL CHECK (frequency_days > 0),
  interest_method TEXT NOT NULL CHECK (
    interest_method IN ('reducing_balance','flat','simple','zero_interest')
  ),
  tenor_days INTEGER NOT NULL CHECK (tenor_days > 0),
  grace_period_days INTEGER NOT NULL CHECK (grace_period_days >= 0),
  repayment_installment_count INTEGER NOT NULL CHECK (
    repayment_installment_count BETWEEN 1 AND 600
  ),
  upfront_item_count INTEGER NOT NULL CHECK (upfront_item_count IN (0,1)),
  principal_total_minor BIGINT NOT NULL CHECK (principal_total_minor > 0),
  interest_total_minor BIGINT NOT NULL CHECK (interest_total_minor >= 0),
  fee_total_minor BIGINT NOT NULL CHECK (fee_total_minor >= 0),
  repayable_total_minor BIGINT NOT NULL,
  offer_hash VARCHAR(64) NOT NULL CHECK (offer_hash ~ '^[a-f0-9]{64}$'),
  schedule_snapshot JSONB NOT NULL CHECK (jsonb_typeof(schedule_snapshot) = 'object'),
  schedule_hash VARCHAR(64) NOT NULL CHECK (schedule_hash ~ '^[a-f0-9]{64}$'),
  generated_by UUID NOT NULL REFERENCES users(id),
  generated_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY (application_id,organization_id) REFERENCES loan_applications(id,organization_id),
  FOREIGN KEY (offer_id,application_id,organization_id)
    REFERENCES loan_offers(id,application_id,organization_id),
  UNIQUE (offer_id,organization_id),
  UNIQUE (organization_id,application_id,version),
  UNIQUE (id,organization_id),
  UNIQUE (id,application_id,organization_id),
  CHECK (repayable_total_minor = principal_total_minor + interest_total_minor + fee_total_minor)
);

CREATE TABLE loan_repayment_installments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  schedule_id UUID NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence BETWEEN 0 AND 600),
  kind TEXT NOT NULL CHECK (kind IN ('upfront','repayment')),
  due_offset_days INTEGER NOT NULL CHECK (due_offset_days >= 0),
  opening_principal_minor BIGINT NOT NULL CHECK (opening_principal_minor >= 0),
  principal_due_minor BIGINT NOT NULL CHECK (principal_due_minor >= 0),
  interest_due_minor BIGINT NOT NULL CHECK (interest_due_minor >= 0),
  fee_due_minor BIGINT NOT NULL CHECK (fee_due_minor >= 0),
  total_due_minor BIGINT NOT NULL CHECK (total_due_minor > 0),
  closing_principal_minor BIGINT NOT NULL CHECK (closing_principal_minor >= 0),
  FOREIGN KEY (schedule_id,organization_id) REFERENCES loan_repayment_schedules(id,organization_id),
  UNIQUE (organization_id,schedule_id,sequence),
  UNIQUE (id,organization_id),
  CHECK (total_due_minor = principal_due_minor + interest_due_minor + fee_due_minor),
  CHECK ((kind='upfront' AND sequence=0 AND due_offset_days=0
      AND principal_due_minor=0 AND interest_due_minor=0
      AND opening_principal_minor=closing_principal_minor)
    OR (kind='repayment' AND sequence>0 AND due_offset_days>0
      AND principal_due_minor>0
      AND closing_principal_minor=opening_principal_minor-principal_due_minor))
);

CREATE INDEX idx_loan_repayment_schedule_application
  ON loan_repayment_schedules(organization_id,application_id);
CREATE INDEX idx_loan_repayment_installment_schedule
  ON loan_repayment_installments(organization_id,schedule_id,sequence);

ALTER TABLE loan_application_events ADD COLUMN schedule_id UUID;
ALTER TABLE loan_application_events ADD CONSTRAINT loan_application_events_schedule_fk
  FOREIGN KEY (schedule_id,application_id,organization_id)
    REFERENCES loan_repayment_schedules(id,application_id,organization_id);

CREATE TRIGGER loan_repayment_schedules_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON loan_repayment_schedules
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();
CREATE TRIGGER loan_repayment_installments_engine_only
  BEFORE INSERT OR UPDATE OR DELETE ON loan_repayment_installments
  FOR EACH ROW EXECUTE FUNCTION require_loan_application_engine();

CREATE OR REPLACE FUNCTION generate_loan_repayment_schedule(
  p_organization UUID,p_actor UUID,p_application UUID,p_offer UUID,
  p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_application loan_applications;
  v_offer loan_offers;
  v_schedule loan_repayment_schedules;
  v_event loan_application_events;
  v_hash TEXT;
  v_schedule_hash TEXT;
  v_snapshot JSONB;
  v_items JSONB:='[]'::JSONB;
  v_item JSONB;
  v_period_days INTEGER;
  v_count INTEGER;
  v_upfront_fees BIGINT;
  v_financed_fees BIGINT;
  v_principal_base BIGINT;
  v_principal_remainder BIGINT;
  v_interest_base BIGINT;
  v_interest_remainder BIGINT;
  v_interest_floor_total BIGINT;
  v_fee_base BIGINT;
  v_fee_remainder BIGINT;
  v_weight_total NUMERIC;
  v_opening BIGINT;
  v_closing BIGINT;
  v_principal_due BIGINT;
  v_interest_due BIGINT;
  v_fee_due BIGINT;
  v_due_offset INTEGER;
  v_sequence INTEGER;
  v_sum_principal BIGINT;
  v_sum_interest BIGINT;
  v_sum_fees BIGINT;
  v_sum_total BIGINT;
BEGIN
  IF NOT has_financial_permission(p_organization,p_actor,'financial.loans.review') THEN
    RAISE EXCEPTION 'Missing financial.loans.review permission';
  END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN
    RAISE EXCEPTION 'Schedule idempotency evidence is invalid';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_organization::TEXT||':loan-application:'||p_application::TEXT,0)
  );
  SELECT * INTO v_event FROM loan_application_events
    WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
  IF v_event.id IS NOT NULL THEN
    IF v_event.application_id<>p_application OR v_event.offer_id<>p_offer OR v_event.schedule_id IS NULL THEN
      RAISE EXCEPTION 'Idempotency key reused with different schedule facts';
    END IF;
    SELECT * INTO v_schedule FROM loan_repayment_schedules
      WHERE id=v_event.schedule_id AND organization_id=p_organization;
    IF v_schedule.id IS NULL OR v_event.request_hash<>encode(digest(convert_to(concat_ws('|',
      p_organization::TEXT,p_actor::TEXT,p_application::TEXT,p_offer::TEXT,
      v_schedule.offer_hash,v_schedule.algorithm_version),'UTF8'),'sha256'),'hex')
    THEN RAISE EXCEPTION 'Stored schedule replay evidence is invalid'; END IF;
    RETURN jsonb_build_object('schedule',to_jsonb(v_schedule),
      'installments',(SELECT COALESCE(jsonb_agg(to_jsonb(item) ORDER BY item.sequence),'[]'::JSONB)
        FROM loan_repayment_installments item WHERE item.schedule_id=v_schedule.id));
  END IF;

  SELECT * INTO v_application FROM loan_applications
    WHERE id=p_application AND organization_id=p_organization FOR UPDATE;
  SELECT * INTO v_offer FROM loan_offers
    WHERE id=p_offer AND application_id=p_application AND organization_id=p_organization FOR UPDATE;
  IF v_application.id IS NULL OR v_application.state<>'accepted'
    OR v_application.applicant_user_id=p_actor
    OR v_offer.id IS NULL OR v_offer.state<>'accepted'
  THEN RAISE EXCEPTION 'Accepted offer is not eligible for independent schedule generation'; END IF;
  IF EXISTS(SELECT 1 FROM loan_repayment_schedules
    WHERE offer_id=p_offer AND organization_id=p_organization)
  THEN RAISE EXCEPTION 'Contractual schedule already exists for this offer'; END IF;

  v_period_days:=loan_repayment_frequency_days(v_offer.repayment_frequency,v_offer.tenor_days);
  IF v_period_days IS NULL OR v_period_days<=0 THEN RAISE EXCEPTION 'Repayment frequency is unsupported'; END IF;
  v_count:=CASE WHEN v_offer.repayment_frequency='bullet' THEN 1
    ELSE CEIL(v_offer.tenor_days::NUMERIC/v_period_days::NUMERIC)::INTEGER END;
  IF v_count NOT BETWEEN 1 AND 600 OR v_count>v_offer.principal_minor THEN
    RAISE EXCEPTION 'Repayment installment count is outside the supported contractual bound';
  END IF;

  v_upfront_fees:=calculate_loan_schedule_upfront_fees(v_offer.principal_minor,v_offer.fees);
  IF v_upfront_fees<0 OR v_upfront_fees>v_offer.total_fees_minor THEN
    RAISE EXCEPTION 'Offer fee timing does not reconcile'; END IF;
  v_financed_fees:=v_offer.total_fees_minor-v_upfront_fees;
  v_principal_base:=v_offer.principal_minor/v_count;
  v_principal_remainder:=v_offer.principal_minor-v_principal_base*v_count;
  v_fee_base:=v_financed_fees/v_count;
  v_fee_remainder:=v_financed_fees-v_fee_base*v_count;

  IF v_offer.interest_method='reducing_balance' THEN
    SELECT SUM((v_offer.principal_minor-v_principal_base*(position-1))::NUMERIC)
      INTO v_weight_total FROM generate_series(1,v_count) position;
    SELECT COALESCE(SUM(FLOOR(v_offer.total_interest_minor::NUMERIC
      *(v_offer.principal_minor-v_principal_base*(position-1))::NUMERIC/v_weight_total)::BIGINT),0)
      INTO v_interest_floor_total FROM generate_series(1,v_count) position;
    v_interest_remainder:=v_offer.total_interest_minor-v_interest_floor_total;
  ELSE
    v_interest_base:=v_offer.total_interest_minor/v_count;
    v_interest_remainder:=v_offer.total_interest_minor-v_interest_base*v_count;
  END IF;

  IF v_upfront_fees>0 THEN
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'sequence',0,'kind','upfront','dueOffsetDays',0,
      'openingPrincipalMinor',v_offer.principal_minor,'principalDueMinor',0,
      'interestDueMinor',0,'feeDueMinor',v_upfront_fees,'totalDueMinor',v_upfront_fees,
      'closingPrincipalMinor',v_offer.principal_minor
    ));
  END IF;

  v_opening:=v_offer.principal_minor;
  FOR v_sequence IN 1..v_count LOOP
    v_principal_due:=v_principal_base+CASE WHEN v_sequence=v_count THEN v_principal_remainder ELSE 0 END;
    IF v_offer.interest_method='reducing_balance' THEN
      v_interest_due:=FLOOR(v_offer.total_interest_minor::NUMERIC*v_opening::NUMERIC/v_weight_total)::BIGINT
        +CASE WHEN v_sequence<=v_interest_remainder THEN 1 ELSE 0 END;
    ELSE
      v_interest_due:=v_interest_base+CASE WHEN v_sequence<=v_interest_remainder THEN 1 ELSE 0 END;
    END IF;
    v_fee_due:=v_fee_base+CASE WHEN v_sequence<=v_fee_remainder THEN 1 ELSE 0 END;
    v_closing:=v_opening-v_principal_due;
    v_due_offset:=v_offer.grace_period_days+LEAST(v_offer.tenor_days,v_sequence*v_period_days);
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'sequence',v_sequence,'kind','repayment','dueOffsetDays',v_due_offset,
      'openingPrincipalMinor',v_opening,'principalDueMinor',v_principal_due,
      'interestDueMinor',v_interest_due,'feeDueMinor',v_fee_due,
      'totalDueMinor',v_principal_due+v_interest_due+v_fee_due,
      'closingPrincipalMinor',v_closing
    ));
    v_opening:=v_closing;
  END LOOP;

  SELECT COALESCE(SUM((entry->>'principalDueMinor')::BIGINT),0),
    COALESCE(SUM((entry->>'interestDueMinor')::BIGINT),0),
    COALESCE(SUM((entry->>'feeDueMinor')::BIGINT),0),
    COALESCE(SUM((entry->>'totalDueMinor')::BIGINT),0)
    INTO v_sum_principal,v_sum_interest,v_sum_fees,v_sum_total
    FROM jsonb_array_elements(v_items) entry;
  IF v_opening<>0 OR v_sum_principal<>v_offer.principal_minor
    OR v_sum_interest<>v_offer.total_interest_minor OR v_sum_fees<>v_offer.total_fees_minor
    OR v_sum_total<>v_offer.total_repayable_minor
  THEN RAISE EXCEPTION 'Generated schedule does not reconcile to the accepted offer'; END IF;

  v_snapshot:=jsonb_build_object(
    'algorithmVersion','CRD-04.SCHEDULE.1','dueDateBasis','days_after_confirmed_disbursement',
    'offerId',v_offer.id,'offerHash',v_offer.offer_hash,'currency',v_offer.currency,
    'repaymentFrequency',v_offer.repayment_frequency,'frequencyDays',v_period_days,
    'interestMethod',v_offer.interest_method,'tenorDays',v_offer.tenor_days,
    'gracePeriodDays',v_offer.grace_period_days,'repaymentInstallmentCount',v_count,
    'principalTotalMinor',v_offer.principal_minor,'interestTotalMinor',v_offer.total_interest_minor,
    'feeTotalMinor',v_offer.total_fees_minor,'repayableTotalMinor',v_offer.total_repayable_minor,
    'feeRules',v_offer.fees,
    'repaymentAllocationOrder',to_jsonb(v_offer.repayment_allocation_order),
    'penaltyCompoundingAllowed',v_offer.penalty_compounding_allowed,
    'penaltyCompoundingLegalBasis',v_offer.penalty_compounding_legal_basis,
    'installments',v_items
  );
  v_schedule_hash:=encode(digest(convert_to(v_snapshot::TEXT,'UTF8'),'sha256'),'hex');
  v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_application::TEXT,
    p_offer::TEXT,v_offer.offer_hash,'CRD-04.SCHEDULE.1'),'UTF8'),'sha256'),'hex');

  PERFORM set_config('microfams.loan_application_engine','on',TRUE);
  INSERT INTO loan_repayment_schedules(organization_id,application_id,offer_id,currency,
    algorithm_version,due_date_basis,repayment_frequency,frequency_days,interest_method,tenor_days,
    grace_period_days,repayment_installment_count,upfront_item_count,principal_total_minor,
    interest_total_minor,fee_total_minor,repayable_total_minor,offer_hash,schedule_snapshot,
    schedule_hash,generated_by,generated_at)
  VALUES(p_organization,p_application,p_offer,v_offer.currency,'CRD-04.SCHEDULE.1',
    'days_after_confirmed_disbursement',v_offer.repayment_frequency,v_period_days,v_offer.interest_method,
    v_offer.tenor_days,v_offer.grace_period_days,v_count,CASE WHEN v_upfront_fees>0 THEN 1 ELSE 0 END,
    v_offer.principal_minor,v_offer.total_interest_minor,v_offer.total_fees_minor,
    v_offer.total_repayable_minor,v_offer.offer_hash,v_snapshot,v_schedule_hash,p_actor,p_at)
  RETURNING * INTO v_schedule;

  INSERT INTO loan_repayment_installments(organization_id,schedule_id,sequence,kind,due_offset_days,
    opening_principal_minor,principal_due_minor,interest_due_minor,fee_due_minor,total_due_minor,
    closing_principal_minor)
  SELECT p_organization,v_schedule.id,(entry->>'sequence')::INTEGER,entry->>'kind',
    (entry->>'dueOffsetDays')::INTEGER,(entry->>'openingPrincipalMinor')::BIGINT,
    (entry->>'principalDueMinor')::BIGINT,(entry->>'interestDueMinor')::BIGINT,
    (entry->>'feeDueMinor')::BIGINT,(entry->>'totalDueMinor')::BIGINT,
    (entry->>'closingPrincipalMinor')::BIGINT
  FROM jsonb_array_elements(v_items) entry;

  INSERT INTO loan_application_events(organization_id,application_id,offer_id,schedule_id,action,actor_id,
    idempotency_key,request_hash,evidence,occurred_at)
  VALUES(p_organization,p_application,p_offer,v_schedule.id,'repayment_schedule_generated',p_actor,
    p_idempotency_key,v_hash,jsonb_build_object('schedule_hash',v_schedule.schedule_hash,
      'algorithm_version',v_schedule.algorithm_version,'repayment_installment_count',v_count,
      'upfront_item_count',v_schedule.upfront_item_count),p_at);
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,
    after_value,occurred_at)
  VALUES(p_organization,p_actor,'LOAN_REPAYMENT_SCHEDULE_GENERATED','loan_repayment_schedule',
    v_schedule.id::TEXT,jsonb_build_object('application_id',p_application,'offer_id',p_offer,
      'schedule_hash',v_schedule.schedule_hash,'repayable_total_minor',v_schedule.repayable_total_minor),p_at);

  RETURN jsonb_build_object('schedule',to_jsonb(v_schedule),'installments',v_items);
END $$;

CREATE OR REPLACE FUNCTION list_loan_applications(p_organization UUID,p_actor UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_can_review BOOLEAN;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM organization_memberships
    WHERE organization_id=p_organization AND user_id=p_actor AND status='active')
  THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
  v_can_review:=has_financial_permission(p_organization,p_actor,'financial.loans.review');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'application',to_jsonb(application),
      'decisions',(SELECT COALESCE(jsonb_agg(to_jsonb(decision) ORDER BY decision.sequence),'[]'::JSONB)
        FROM loan_application_decisions decision WHERE decision.organization_id=p_organization
          AND decision.application_id=application.id),
      'adverse_review',(SELECT to_jsonb(review) FROM loan_adverse_reviews review
        WHERE review.organization_id=p_organization AND review.application_id=application.id),
      'offers',(SELECT COALESCE(jsonb_agg(to_jsonb(offer) ORDER BY offer.version),'[]'::JSONB)
        FROM loan_offers offer WHERE offer.organization_id=p_organization
          AND offer.application_id=application.id),
      'repayment_schedules',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'schedule',to_jsonb(schedule),
          'installments',(SELECT COALESCE(jsonb_agg(to_jsonb(item) ORDER BY item.sequence),'[]'::JSONB)
            FROM loan_repayment_installments item WHERE item.organization_id=p_organization
              AND item.schedule_id=schedule.id)
        ) ORDER BY schedule.version),'[]'::JSONB)
        FROM loan_repayment_schedules schedule WHERE schedule.organization_id=p_organization
          AND schedule.application_id=application.id)
    ) ORDER BY application.created_at DESC)
    FROM loan_applications application WHERE application.organization_id=p_organization
      AND (v_can_review OR application.applicant_user_id=p_actor)),'[]'::JSONB);
END $$;

ALTER TABLE loan_repayment_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_repayment_installments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON loan_repayment_schedules,loan_repayment_installments FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON loan_repayment_schedules,loan_repayment_installments FROM service_role;
GRANT SELECT ON loan_repayment_schedules,loan_repayment_installments TO service_role;
REVOKE ALL ON FUNCTION loan_repayment_frequency_days(TEXT,INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION calculate_loan_schedule_upfront_fees(BIGINT,JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION generate_loan_repayment_schedule(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION generate_loan_repayment_schedule(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
