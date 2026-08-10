-- SAV-02: atomic manual contributions and consent-backed standing orders.
-- Existing mandates remain serviceable independently of new-exposure flags.

-- FC-08 cutover accounts predate canonical purposes. Bind their existing,
-- immutable account identities to the approved purpose catalogue.
UPDATE financial_accounts account SET purpose=CASE item.source_type
  WHEN 'wallet' THEN 'individual_wallet_funds' ELSE 'group_wallet_funds' END
FROM wallet_ledger_migration_items item
JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=item.migration_run_id
  AND cutover.organization_id=item.organization_id AND cutover.status='active'
WHERE account.id=item.financial_account_id AND account.organization_id=item.organization_id
  AND account.purpose IS NULL;

-- Cutovers can also be activated after this migration is installed. Bind every
-- newly mapped wallet account at the point the immutable source mapping appears.
CREATE OR REPLACE FUNCTION bind_wallet_cutover_account_purpose() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE expected_purpose TEXT:=CASE NEW.source_type
  WHEN 'wallet' THEN 'individual_wallet_funds'
  WHEN 'group' THEN 'group_wallet_funds'
END;
BEGIN
 IF expected_purpose IS NULL THEN RETURN NEW; END IF;
 UPDATE financial_accounts SET purpose=expected_purpose
 WHERE id=NEW.financial_account_id AND organization_id=NEW.organization_id AND purpose IS NULL;
 IF NOT EXISTS(
   SELECT 1 FROM financial_accounts
   WHERE id=NEW.financial_account_id AND organization_id=NEW.organization_id
     AND purpose=expected_purpose
 ) THEN RAISE EXCEPTION 'Wallet cutover account purpose conflicts with its source type'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS bind_wallet_cutover_account_purpose_trigger ON wallet_ledger_migration_items;
CREATE TRIGGER bind_wallet_cutover_account_purpose_trigger
AFTER INSERT OR UPDATE OF financial_account_id,source_type ON wallet_ledger_migration_items
FOR EACH ROW EXECUTE FUNCTION bind_wallet_cutover_account_purpose();

CREATE TABLE savings_standing_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  enrolment_id UUID NOT NULL,
  member_id UUID NOT NULL REFERENCES users(id),
  product_version_id UUID NOT NULL,
  source_wallet_id UUID NOT NULL REFERENCES user_wallets(id),
  source_account_id UUID NOT NULL,
  currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
  amount_minor BIGINT NOT NULL CHECK(amount_minor>0),
  frequency TEXT NOT NULL CHECK(frequency IN('daily','weekly','monthly','quarterly')),
  state TEXT NOT NULL DEFAULT 'active' CHECK(state IN('active','paused','cancelled')),
  schedule_anchor_at TIMESTAMPTZ NOT NULL,
  next_occurrence INTEGER NOT NULL DEFAULT 0 CHECK(next_occurrence>=0),
  next_due_at TIMESTAMPTZ NOT NULL,
  authorized_disclosure_version TEXT NOT NULL,
  authorized_disclosure_hash VARCHAR(64) NOT NULL CHECK(authorized_disclosure_hash~'^[a-f0-9]{64}$'),
  authorized_at TIMESTAMPTZ NOT NULL,
  consecutive_failures INTEGER NOT NULL DEFAULT 0 CHECK(consecutive_failures>=0),
  last_attempt_at TIMESTAMPTZ,
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY(enrolment_id,organization_id) REFERENCES savings_enrolments(id,organization_id),
  FOREIGN KEY(product_version_id,organization_id) REFERENCES savings_product_versions(id,organization_id),
  FOREIGN KEY(source_account_id,organization_id,currency) REFERENCES financial_accounts(id,organization_id,currency),
  UNIQUE(organization_id,idempotency_key), UNIQUE(id,organization_id),
  CHECK(next_due_at>=schedule_anchor_at)
);
CREATE UNIQUE INDEX uq_open_savings_standing_order ON savings_standing_orders(organization_id,enrolment_id) WHERE state IN('active','paused');
CREATE INDEX idx_due_savings_standing_orders ON savings_standing_orders(next_due_at,organization_id) WHERE state='active';

CREATE TABLE savings_contributions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  enrolment_id UUID NOT NULL,
  member_id UUID NOT NULL REFERENCES users(id),
  source_wallet_id UUID NOT NULL REFERENCES user_wallets(id),
  source_account_id UUID NOT NULL,
  destination_account_id UUID NOT NULL,
  standing_order_id UUID,
  method TEXT NOT NULL CHECK(method IN('manual','standing_order')),
  currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
  amount_minor BIGINT NOT NULL CHECK(amount_minor>0),
  scheduled_for TIMESTAMPTZ,
  journal_entry_id UUID NOT NULL UNIQUE REFERENCES journal_entries(id),
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  contributed_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY(enrolment_id,organization_id) REFERENCES savings_enrolments(id,organization_id),
  FOREIGN KEY(source_account_id,organization_id,currency) REFERENCES financial_accounts(id,organization_id,currency),
  FOREIGN KEY(destination_account_id,organization_id,currency) REFERENCES financial_accounts(id,organization_id,currency),
  FOREIGN KEY(standing_order_id,organization_id) REFERENCES savings_standing_orders(id,organization_id),
  UNIQUE(organization_id,idempotency_key), UNIQUE(id,organization_id),
  CHECK((method='manual' AND standing_order_id IS NULL AND scheduled_for IS NULL)
    OR(method='standing_order' AND standing_order_id IS NOT NULL AND scheduled_for IS NOT NULL))
);
CREATE INDEX idx_savings_contributions_enrolment ON savings_contributions(organization_id,enrolment_id,contributed_at DESC);

CREATE TABLE savings_standing_order_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  standing_order_id UUID NOT NULL,
  scheduled_for TIMESTAMPTZ NOT NULL,
  occurrence INTEGER NOT NULL CHECK(occurrence>=0),
  amount_minor BIGINT NOT NULL CHECK(amount_minor>0),
  state TEXT NOT NULL CHECK(state IN('processing','succeeded','failed')),
  contribution_id UUID,
  failure_code TEXT CHECK(failure_code IS NULL OR failure_code IN('insufficient_funds','enrolment_unavailable','source_unavailable')),
  worker_id TEXT NOT NULL CHECK(length(worker_id) BETWEEN 1 AND 100),
  attempted_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY(standing_order_id,organization_id) REFERENCES savings_standing_orders(id,organization_id),
  FOREIGN KEY(contribution_id,organization_id) REFERENCES savings_contributions(id,organization_id),
  UNIQUE(organization_id,standing_order_id,scheduled_for), UNIQUE(contribution_id),
  CHECK((state='processing' AND contribution_id IS NULL AND failure_code IS NULL AND completed_at IS NULL)
    OR(state='succeeded' AND contribution_id IS NOT NULL AND failure_code IS NULL AND completed_at IS NOT NULL)
    OR(state='failed' AND contribution_id IS NULL AND failure_code IS NOT NULL AND completed_at IS NOT NULL))
);
CREATE INDEX idx_savings_standing_order_attempts ON savings_standing_order_attempts(organization_id,standing_order_id,scheduled_for DESC);

CREATE TABLE savings_standing_order_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  standing_order_id UUID NOT NULL,
  action TEXT NOT NULL CHECK(action IN('created','paused','resumed','cancelled')),
  actor_id UUID NOT NULL REFERENCES users(id),
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),
  occurred_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(standing_order_id,organization_id) REFERENCES savings_standing_orders(id,organization_id),
  UNIQUE(organization_id,idempotency_key)
);

CREATE OR REPLACE FUNCTION require_savings_contribution_engine() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF current_setting('microfams.savings_contribution_engine',TRUE) IS DISTINCT FROM 'on' THEN RAISE EXCEPTION 'SAVINGS_CONTRIBUTION_ENGINE_REQUIRED'; END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER savings_standing_orders_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_standing_orders FOR EACH ROW EXECUTE FUNCTION require_savings_contribution_engine();
CREATE TRIGGER savings_contributions_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_contributions FOR EACH ROW EXECUTE FUNCTION require_savings_contribution_engine();
CREATE TRIGGER savings_standing_order_attempts_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_standing_order_attempts FOR EACH ROW EXECUTE FUNCTION require_savings_contribution_engine();
CREATE TRIGGER savings_standing_order_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_standing_order_events FOR EACH ROW EXECUTE FUNCTION require_savings_contribution_engine();

CREATE OR REPLACE FUNCTION savings_schedule_occurrence(p_anchor TIMESTAMPTZ,p_frequency TEXT,p_occurrence INTEGER)
RETURNS TIMESTAMPTZ LANGUAGE plpgsql IMMUTABLE SET search_path=public AS $$
BEGIN
 IF p_anchor IS NULL OR p_occurrence<0 THEN RAISE EXCEPTION 'Savings schedule is invalid'; END IF;
 CASE p_frequency
  WHEN 'daily' THEN RETURN p_anchor+make_interval(days=>p_occurrence);
  WHEN 'weekly' THEN RETURN p_anchor+make_interval(days=>7*p_occurrence);
  WHEN 'monthly' THEN RETURN p_anchor+make_interval(months=>p_occurrence);
  WHEN 'quarterly' THEN RETURN p_anchor+make_interval(months=>3*p_occurrence);
  ELSE RAISE EXCEPTION 'Savings schedule frequency is invalid';
 END CASE;
END $$;

CREATE OR REPLACE FUNCTION post_savings_contribution_internal(
 p_organization UUID,p_actor UUID,p_enrolment UUID,p_amount_minor BIGINT,p_method TEXT,
 p_standing_order UUID,p_scheduled_for TIMESTAMPTZ,p_idempotency_key TEXT,p_correlation_id UUID,p_at TIMESTAMPTZ
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE e savings_enrolments; v savings_product_versions; w user_wallets; a financial_accounts;
 old savings_contributions; c savings_contributions; h TEXT; holds BIGINT; available BIGINT; journal UUID; lines JSONB;
BEGIN
 IF p_amount_minor IS NULL OR p_amount_minor<=0 THEN RAISE EXCEPTION 'Contribution amount must be positive minor units'; END IF;
 IF p_method NOT IN('manual','standing_order') OR(p_method='manual' AND(p_standing_order IS NOT NULL OR p_scheduled_for IS NOT NULL))
   OR(p_method='standing_order' AND(p_standing_order IS NULL OR p_scheduled_for IS NULL)) THEN RAISE EXCEPTION 'Contribution scheduling evidence is invalid'; END IF;
 IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Idempotency key is invalid'; END IF;
 IF p_correlation_id IS NULL OR p_at IS NULL THEN RAISE EXCEPTION 'Contribution correlation and time are required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active') THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
 SELECT * INTO e FROM savings_enrolments WHERE id=p_enrolment AND organization_id=p_organization AND member_id=p_actor FOR UPDATE;
 IF e.id IS NULL OR e.state<>'active' THEN RAISE EXCEPTION 'Active savings enrolment not found'; END IF;
 SELECT * INTO v FROM savings_product_versions WHERE id=e.product_version_id AND organization_id=p_organization;
 IF p_amount_minor<v.minimum_contribution_minor OR p_amount_minor>v.maximum_contribution_minor THEN RAISE EXCEPTION 'Contribution amount is outside the product limits'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_enrolment::TEXT,p_amount_minor::TEXT,p_method,
   COALESCE(p_standing_order::TEXT,''),COALESCE(p_scheduled_for::TEXT,''),p_correlation_id::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-contribution:'||p_idempotency_key,0));
 SELECT * INTO old FROM savings_contributions WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF old.id IS NOT NULL THEN IF old.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different contribution facts'; END IF; RETURN to_jsonb(old); END IF;
 SELECT * INTO w FROM user_wallets WHERE organization_id=p_organization AND user_id=p_actor AND status='ACTIVE' FOR UPDATE;
 IF w.id IS NULL OR NOT wallet_cutover_is_active(p_organization) THEN RAISE EXCEPTION 'Active ledger wallet is unavailable'; END IF;
 SELECT account.* INTO a FROM wallet_ledger_migration_items item
 JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=item.migration_run_id
   AND cutover.organization_id=item.organization_id AND cutover.status='active'
 JOIN financial_accounts account ON account.id=item.financial_account_id AND account.organization_id=item.organization_id
 WHERE item.organization_id=p_organization AND item.source_type='wallet' AND item.source_id=w.id
   AND account.owner_type='user' AND account.owner_id=p_actor AND account.currency=e.currency
   AND account.account_class='liability' AND account.normal_side='credit' AND account.status='active' FOR UPDATE OF account;
 IF a.id IS NULL THEN RAISE EXCEPTION 'Canonical wallet account is unavailable'; END IF;
 IF p_method='standing_order' AND NOT EXISTS(SELECT 1 FROM savings_standing_orders WHERE id=p_standing_order AND organization_id=p_organization
   AND enrolment_id=p_enrolment AND member_id=p_actor AND source_wallet_id=w.id AND source_account_id=a.id) THEN RAISE EXCEPTION 'Standing order does not match the contribution'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':wallet-source:'||a.id::TEXT,0));
 SELECT COALESCE(sum(amount_minor),0)::BIGINT INTO holds FROM fund_reservations WHERE organization_id=p_organization
   AND wallet_account_id=a.id AND state='active' AND expires_at>p_at;
 available:=wallet_account_balance_minor(a.id)-holds;
 IF available<p_amount_minor THEN RAISE EXCEPTION 'Insufficient available wallet funds'; END IF;
 lines:=jsonb_build_array(
   jsonb_build_object('account_id',a.id,'line_number',1,'side','debit','amount_minor',p_amount_minor,'memo','Member wallet savings transfer'),
   jsonb_build_object('account_id',e.principal_account_id,'line_number',2,'side','credit','amount_minor',p_amount_minor,'memo','Savings principal contribution'));
 journal:=post_financial_journal(p_organization,e.currency,p_at::DATE,'savings.contribution',p_enrolment::TEXT,p_idempotency_key,h,
   p_correlation_id,'Savings principal contribution',p_actor,lines);
 PERFORM set_config('microfams.savings_contribution_engine','on',TRUE);
 INSERT INTO savings_contributions(organization_id,enrolment_id,member_id,source_wallet_id,source_account_id,destination_account_id,
   standing_order_id,method,currency,amount_minor,scheduled_for,journal_entry_id,idempotency_key,request_hash,correlation_id,contributed_at)
 VALUES(p_organization,p_enrolment,p_actor,w.id,a.id,e.principal_account_id,p_standing_order,p_method,e.currency,p_amount_minor,
   p_scheduled_for,journal,p_idempotency_key,h,p_correlation_id,p_at) RETURNING * INTO c;
 PERFORM sync_wallet_ledger_cache(p_organization,'user',w.id,a.id);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,'SAVINGS_CONTRIBUTION_POSTED','savings_contribution',c.id::TEXT,
   jsonb_build_object('enrolment_id',p_enrolment,'amount_minor',p_amount_minor,'currency',e.currency,'method',p_method,'journal_entry_id',journal),p_at);
 RETURN to_jsonb(c);
END $$;

CREATE OR REPLACE FUNCTION post_savings_contribution(p_organization UUID,p_actor UUID,p_enrolment UUID,p_amount_minor BIGINT,
 p_idempotency_key TEXT,p_correlation_id UUID,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN RETURN post_savings_contribution_internal(p_organization,p_actor,p_enrolment,p_amount_minor,'manual',NULL,NULL,p_idempotency_key,p_correlation_id,p_at); END $$;

CREATE OR REPLACE FUNCTION create_savings_standing_order(p_organization UUID,p_actor UUID,p_enrolment UUID,p_amount_minor BIGINT,
 p_first_due_at TIMESTAMPTZ,p_disclosure_version TEXT,p_disclosure_hash TEXT,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW())
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE e savings_enrolments; v savings_product_versions; w user_wallets; a financial_accounts; old savings_standing_orders; m savings_standing_orders; h TEXT;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active') THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
 SELECT * INTO e FROM savings_enrolments WHERE id=p_enrolment AND organization_id=p_organization AND member_id=p_actor AND state='active' FOR UPDATE;
 IF e.id IS NULL THEN RAISE EXCEPTION 'Active savings enrolment not found'; END IF;
 SELECT * INTO v FROM savings_product_versions WHERE id=e.product_version_id AND organization_id=p_organization;
 IF v.contribution_frequency='manual' THEN RAISE EXCEPTION 'Product does not allow standing orders'; END IF;
 IF p_amount_minor<v.minimum_contribution_minor OR p_amount_minor>v.maximum_contribution_minor THEN RAISE EXCEPTION 'Standing-order amount is outside the product limits'; END IF;
 IF p_disclosure_version IS DISTINCT FROM e.accepted_disclosure_version OR lower(p_disclosure_hash) IS DISTINCT FROM e.accepted_disclosure_hash THEN RAISE EXCEPTION 'Standing-order authorization does not match the enrolled disclosure'; END IF;
 IF p_first_due_at<p_at OR p_first_due_at>p_at+INTERVAL '366 days' THEN RAISE EXCEPTION 'First due time is outside the allowed window'; END IF;
 IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Idempotency key is invalid'; END IF;
 SELECT * INTO w FROM user_wallets WHERE organization_id=p_organization AND user_id=p_actor AND status='ACTIVE' FOR UPDATE;
 IF w.id IS NULL OR NOT wallet_cutover_is_active(p_organization) THEN RAISE EXCEPTION 'Active ledger wallet is unavailable'; END IF;
 SELECT account.* INTO a FROM wallet_ledger_migration_items item
 JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=item.migration_run_id
   AND cutover.organization_id=item.organization_id AND cutover.status='active'
 JOIN financial_accounts account ON account.id=item.financial_account_id AND account.organization_id=item.organization_id
 WHERE item.organization_id=p_organization AND item.source_type='wallet' AND item.source_id=w.id
   AND account.owner_type='user' AND account.owner_id=p_actor AND account.currency=e.currency
   AND account.account_class='liability' AND account.normal_side='credit' AND account.status='active';
 IF a.id IS NULL THEN RAISE EXCEPTION 'Canonical wallet account is unavailable'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_enrolment::TEXT,p_amount_minor::TEXT,
   p_first_due_at::TEXT,p_disclosure_version,lower(p_disclosure_hash)),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-standing-order:'||p_idempotency_key,0));
 SELECT * INTO old FROM savings_standing_orders WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF old.id IS NOT NULL THEN IF old.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different standing-order facts'; END IF; RETURN to_jsonb(old); END IF;
 PERFORM set_config('microfams.savings_contribution_engine','on',TRUE);
 INSERT INTO savings_standing_orders(organization_id,enrolment_id,member_id,product_version_id,source_wallet_id,source_account_id,currency,
   amount_minor,frequency,schedule_anchor_at,next_due_at,authorized_disclosure_version,authorized_disclosure_hash,authorized_at,idempotency_key,request_hash,created_at,updated_at)
 VALUES(p_organization,p_enrolment,p_actor,e.product_version_id,w.id,a.id,e.currency,p_amount_minor,v.contribution_frequency,p_first_due_at,
   p_first_due_at,e.accepted_disclosure_version,e.accepted_disclosure_hash,p_at,p_idempotency_key,h,p_at,p_at) RETURNING * INTO m;
 INSERT INTO savings_standing_order_events(organization_id,standing_order_id,action,actor_id,idempotency_key,request_hash,occurred_at)
 VALUES(p_organization,m.id,'created',p_actor,p_idempotency_key,h,p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,'SAVINGS_STANDING_ORDER_CREATED','savings_standing_order',m.id::TEXT,
   jsonb_build_object('enrolment_id',p_enrolment,'amount_minor',p_amount_minor,'currency',e.currency,'frequency',v.contribution_frequency,'first_due_at',p_first_due_at),p_at);
 RETURN to_jsonb(m);
END $$;

CREATE OR REPLACE FUNCTION transition_savings_standing_order(p_organization UUID,p_actor UUID,p_standing_order UUID,p_action TEXT,
 p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE m savings_standing_orders; ev savings_standing_order_events; h TEXT; occurrence INTEGER; due TIMESTAMPTZ; event_action TEXT;
BEGIN
 IF p_action NOT IN('pause','resume','cancel') THEN RAISE EXCEPTION 'Standing-order action is invalid'; END IF;
 IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Idempotency key is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active') THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_standing_order::TEXT,p_action),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-standing-order:'||p_standing_order::TEXT,0));
 SELECT * INTO ev FROM savings_standing_order_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF ev.id IS NOT NULL THEN IF ev.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different standing-order facts'; END IF;
  SELECT * INTO m FROM savings_standing_orders WHERE id=ev.standing_order_id; RETURN to_jsonb(m); END IF;
 SELECT * INTO m FROM savings_standing_orders WHERE id=p_standing_order AND organization_id=p_organization AND member_id=p_actor FOR UPDATE;
 IF m.id IS NULL THEN RAISE EXCEPTION 'Standing order not found'; END IF;
 IF(p_action='pause' AND m.state<>'active') OR(p_action='resume' AND m.state<>'paused') OR(p_action='cancel' AND m.state NOT IN('active','paused')) THEN RAISE EXCEPTION 'Standing-order transition is invalid'; END IF;
 occurrence:=m.next_occurrence; due:=m.next_due_at;
 IF p_action='resume' THEN WHILE due<p_at LOOP occurrence:=occurrence+1; due:=savings_schedule_occurrence(m.schedule_anchor_at,m.frequency,occurrence); END LOOP; END IF;
 event_action:=CASE p_action WHEN 'pause' THEN 'paused' WHEN 'resume' THEN 'resumed' ELSE 'cancelled' END;
 PERFORM set_config('microfams.savings_contribution_engine','on',TRUE);
 UPDATE savings_standing_orders SET state=CASE p_action WHEN 'pause' THEN 'paused' WHEN 'resume' THEN 'active' ELSE 'cancelled' END,
  next_occurrence=occurrence,next_due_at=due,updated_at=p_at WHERE id=m.id RETURNING * INTO m;
 INSERT INTO savings_standing_order_events(organization_id,standing_order_id,action,actor_id,idempotency_key,request_hash,occurred_at)
 VALUES(p_organization,m.id,event_action,p_actor,p_idempotency_key,h,p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,'SAVINGS_STANDING_ORDER_'||upper(event_action),'savings_standing_order',m.id::TEXT,jsonb_build_object('state',m.state,'next_due_at',m.next_due_at),p_at);
 RETURN to_jsonb(m);
END $$;

CREATE OR REPLACE FUNCTION service_savings_standing_order(p_organization UUID,p_standing_order UUID,p_worker_id TEXT,p_at TIMESTAMPTZ DEFAULT NOW())
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE m savings_standing_orders; e savings_enrolments; attempt savings_standing_order_attempts; c JSONB;
 occurrence INTEGER; due TIMESTAMPTZ; available BIGINT; holds BIGINT; failure TEXT; command_key TEXT; correlation UUID;
BEGIN
 IF p_worker_id IS NULL OR length(p_worker_id) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Standing-order worker is invalid'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-standing-order:'||p_standing_order::TEXT,0));
 SELECT * INTO m FROM savings_standing_orders WHERE id=p_standing_order AND organization_id=p_organization FOR UPDATE;
 IF m.id IS NULL THEN RAISE EXCEPTION 'Standing order not found'; END IF;
 IF m.state<>'active' THEN RETURN jsonb_build_object('standingOrderId',m.id,'state','inactive'); END IF;
 IF m.next_due_at>p_at THEN RETURN jsonb_build_object('standingOrderId',m.id,'state','not_due'); END IF;
 SELECT * INTO attempt FROM savings_standing_order_attempts WHERE organization_id=p_organization AND standing_order_id=m.id AND scheduled_for=m.next_due_at;
 IF attempt.id IS NOT NULL THEN RETURN to_jsonb(attempt); END IF;
 occurrence:=m.next_occurrence+1; due:=savings_schedule_occurrence(m.schedule_anchor_at,m.frequency,occurrence);
 WHILE due<=p_at LOOP
  occurrence:=occurrence+1; due:=savings_schedule_occurrence(m.schedule_anchor_at,m.frequency,occurrence);
 END LOOP;
 command_key:='sav-standing:'||m.id::TEXT||':'||m.next_occurrence::TEXT;
 correlation:=wallet_reference_uuid(p_organization,'savings.standing',command_key);
 PERFORM set_config('microfams.savings_contribution_engine','on',TRUE);
 INSERT INTO savings_standing_order_attempts(organization_id,standing_order_id,scheduled_for,occurrence,amount_minor,state,worker_id,attempted_at)
 VALUES(p_organization,m.id,m.next_due_at,m.next_occurrence,m.amount_minor,'processing',p_worker_id,p_at) RETURNING * INTO attempt;
 SELECT * INTO e FROM savings_enrolments WHERE id=m.enrolment_id AND organization_id=p_organization;
 IF e.id IS NULL OR e.state<>'active' THEN failure:='enrolment_unavailable';
 ELSIF NOT EXISTS(SELECT 1 FROM user_wallets WHERE id=m.source_wallet_id AND organization_id=p_organization AND user_id=m.member_id AND status='ACTIVE')
   OR NOT EXISTS(SELECT 1 FROM financial_accounts WHERE id=m.source_account_id AND organization_id=p_organization AND currency=m.currency AND purpose='individual_wallet_funds' AND status='active')
   OR NOT wallet_cutover_is_active(p_organization) THEN failure:='source_unavailable';
 ELSE
  PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':wallet-source:'||m.source_account_id::TEXT,0));
  SELECT COALESCE(sum(amount_minor),0)::BIGINT INTO holds FROM fund_reservations WHERE organization_id=p_organization
    AND wallet_account_id=m.source_account_id AND state='active' AND expires_at>p_at;
  available:=wallet_account_balance_minor(m.source_account_id)-holds;
  IF available<m.amount_minor THEN failure:='insufficient_funds'; END IF;
 END IF;
 IF failure IS NOT NULL THEN
  UPDATE savings_standing_order_attempts SET state='failed',failure_code=failure,completed_at=p_at WHERE id=attempt.id RETURNING * INTO attempt;
  UPDATE savings_standing_orders SET next_occurrence=occurrence,next_due_at=due,consecutive_failures=consecutive_failures+1,last_attempt_at=p_at,updated_at=p_at WHERE id=m.id;
  INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
  VALUES(p_organization,m.member_id,'SAVINGS_STANDING_ORDER_FAILED','savings_standing_order_attempt',attempt.id::TEXT,
   jsonb_build_object('standing_order_id',m.id,'failure_code',failure,'scheduled_for',m.next_due_at),p_at);
  RETURN to_jsonb(attempt);
 END IF;
 c:=post_savings_contribution_internal(p_organization,m.member_id,m.enrolment_id,m.amount_minor,'standing_order',m.id,m.next_due_at,command_key,correlation,p_at);
 UPDATE savings_standing_order_attempts SET state='succeeded',contribution_id=(c->>'id')::UUID,completed_at=p_at WHERE id=attempt.id RETURNING * INTO attempt;
 UPDATE savings_standing_orders SET next_occurrence=occurrence,next_due_at=due,consecutive_failures=0,last_attempt_at=p_at,updated_at=p_at WHERE id=m.id;
 RETURN to_jsonb(attempt);
END $$;

CREATE OR REPLACE FUNCTION list_member_savings_contributions(p_organization UUID,p_actor UUID,p_enrolment UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM savings_enrolments WHERE id=p_enrolment AND organization_id=p_organization AND member_id=p_actor) THEN RAISE EXCEPTION 'Savings enrolment not found'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.contributed_at DESC) FROM savings_contributions c WHERE c.organization_id=p_organization AND c.enrolment_id=p_enrolment),'[]'::JSONB);
END $$;
CREATE OR REPLACE FUNCTION list_member_savings_standing_orders(p_organization UUID,p_actor UUID,p_enrolment UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM savings_enrolments WHERE id=p_enrolment AND organization_id=p_organization AND member_id=p_actor) THEN RAISE EXCEPTION 'Savings enrolment not found'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('standingOrder',to_jsonb(m),'attempts',
  COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.scheduled_for DESC) FROM savings_standing_order_attempts a WHERE a.organization_id=m.organization_id AND a.standing_order_id=m.id),'[]'::JSONB)) ORDER BY m.created_at DESC)
  FROM savings_standing_orders m WHERE m.organization_id=p_organization AND m.enrolment_id=p_enrolment),'[]'::JSONB);
END $$;

ALTER TABLE savings_standing_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_contributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_standing_order_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_standing_order_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON savings_standing_orders,savings_contributions,savings_standing_order_attempts,savings_standing_order_events FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON savings_standing_orders,savings_contributions,savings_standing_order_attempts,savings_standing_order_events FROM service_role;
GRANT SELECT ON savings_standing_orders,savings_contributions,savings_standing_order_attempts,savings_standing_order_events TO service_role;
REVOKE ALL ON FUNCTION savings_schedule_occurrence(TIMESTAMPTZ,TEXT,INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION post_savings_contribution_internal(UUID,UUID,UUID,BIGINT,TEXT,UUID,TIMESTAMPTZ,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION post_savings_contribution(UUID,UUID,UUID,BIGINT,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_savings_standing_order(UUID,UUID,UUID,BIGINT,TIMESTAMPTZ,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION transition_savings_standing_order(UUID,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION service_savings_standing_order(UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_member_savings_contributions(UUID,UUID,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_member_savings_standing_orders(UUID,UUID,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION post_savings_contribution(UUID,UUID,UUID,BIGINT,TEXT,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION create_savings_standing_order(UUID,UUID,UUID,BIGINT,TIMESTAMPTZ,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION transition_savings_standing_order(UUID,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION service_savings_standing_order(UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION list_member_savings_contributions(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION list_member_savings_standing_orders(UUID,UUID,UUID) TO service_role;
