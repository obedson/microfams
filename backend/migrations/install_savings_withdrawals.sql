-- SAV-04: governed savings withdrawals into the member's personal wallet.
-- Bank payout remains a separate, provider-neutral wallet payout operation.

SET search_path=public,extensions;

INSERT INTO financial_account_purpose_rules(
  purpose,account_class,normal_side,allowed_owner_types,is_control
) VALUES(
  'savings_forfeited_return_revenue','revenue','credit',ARRAY['organization','system'],FALSE
) ON CONFLICT (purpose) DO NOTHING;

CREATE TABLE savings_withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  enrolment_id UUID NOT NULL,
  product_version_id UUID NOT NULL,
  member_id UUID NOT NULL REFERENCES users(id),
  destination_wallet_id UUID NOT NULL,
  destination_account_id UUID NOT NULL,
  principal_account_id UUID NOT NULL,
  accrued_return_account_id UUID NOT NULL,
  currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'),
  requested_minor BIGINT NOT NULL CHECK(requested_minor>0),
  principal_withdrawn_minor BIGINT NOT NULL CHECK(principal_withdrawn_minor>=0),
  return_withdrawn_minor BIGINT NOT NULL CHECK(return_withdrawn_minor>=0),
  return_forfeited_minor BIGINT NOT NULL CHECK(return_forfeited_minor>=0),
  fee_minor BIGINT NOT NULL CHECK(fee_minor>=0),
  net_payout_minor BIGINT NOT NULL CHECK(net_payout_minor>0),
  is_early BOOLEAN NOT NULL,
  lock_expires_at_snapshot TIMESTAMPTZ,
  early_withdrawal_rule TEXT NOT NULL
    CHECK(early_withdrawal_rule IN('blocked','allowed','forfeit_returns','fee')),
  disclosure_version TEXT NOT NULL CHECK(length(btrim(disclosure_version)) BETWEEN 1 AND 80),
  disclosure_hash VARCHAR(64) NOT NULL CHECK(disclosure_hash~'^[a-f0-9]{64}$'),
  allocation_version TEXT NOT NULL
    CHECK(allocation_version='returns_then_principal_v1'),
  principal_balance_snapshot_minor BIGINT NOT NULL CHECK(principal_balance_snapshot_minor>=0),
  return_balance_snapshot_minor BIGINT NOT NULL CHECK(return_balance_snapshot_minor>=0),
  state TEXT NOT NULL DEFAULT 'pending_approval'
    CHECK(state IN('pending_approval','settled','rejected','cancelled')),
  created_by UUID NOT NULL REFERENCES users(id),
  creation_idempotency_key TEXT NOT NULL CHECK(length(creation_idempotency_key) BETWEEN 8 AND 160),
  creation_request_hash VARCHAR(64) NOT NULL CHECK(creation_request_hash~'^[a-f0-9]{64}$'),
  creation_correlation_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  reviewed_by UUID REFERENCES users(id),
  review_action TEXT CHECK(review_action IS NULL OR review_action IN('approved','rejected','cancelled')),
  review_reason TEXT CHECK(review_reason IS NULL OR length(btrim(review_reason)) BETWEEN 8 AND 1000),
  review_idempotency_key TEXT CHECK(review_idempotency_key IS NULL OR length(review_idempotency_key) BETWEEN 8 AND 160),
  review_request_hash VARCHAR(64) CHECK(review_request_hash IS NULL OR review_request_hash~'^[a-f0-9]{64}$'),
  review_correlation_id UUID,
  reviewed_at TIMESTAMPTZ,
  journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  settled_at TIMESTAMPTZ,
  FOREIGN KEY(enrolment_id,organization_id) REFERENCES savings_enrolments(id,organization_id),
  FOREIGN KEY(product_version_id,organization_id) REFERENCES savings_product_versions(id,organization_id),
  FOREIGN KEY(destination_wallet_id) REFERENCES user_wallets(id),
  FOREIGN KEY(destination_account_id,organization_id,currency) REFERENCES financial_accounts(id,organization_id,currency),
  FOREIGN KEY(principal_account_id,organization_id,currency) REFERENCES financial_accounts(id,organization_id,currency),
  FOREIGN KEY(accrued_return_account_id,organization_id,currency) REFERENCES financial_accounts(id,organization_id,currency),
  UNIQUE(organization_id,creation_idempotency_key),
  UNIQUE(organization_id,review_idempotency_key),
  UNIQUE(id,organization_id),
  CHECK(requested_minor=principal_withdrawn_minor+return_withdrawn_minor),
  CHECK(net_payout_minor=requested_minor-fee_minor),
  CHECK(NOT is_early OR early_withdrawal_rule<>'blocked'),
  CHECK(is_early OR(fee_minor=0 AND return_forfeited_minor=0)),
  CHECK((is_early AND early_withdrawal_rule='fee')=(fee_minor>0)),
  CHECK(NOT(is_early AND early_withdrawal_rule='forfeit_returns') OR return_withdrawn_minor=0),
  CHECK(return_forfeited_minor=0 OR(is_early AND early_withdrawal_rule='forfeit_returns')),
  CHECK(
    (state='pending_approval' AND reviewed_by IS NULL AND review_action IS NULL
      AND review_reason IS NULL AND review_idempotency_key IS NULL AND review_request_hash IS NULL
      AND review_correlation_id IS NULL AND reviewed_at IS NULL AND journal_entry_id IS NULL AND settled_at IS NULL)
    OR(state='settled' AND reviewed_by IS NOT NULL AND reviewed_by<>created_by AND review_action='approved'
      AND review_reason IS NULL AND review_idempotency_key IS NOT NULL AND review_request_hash IS NOT NULL
      AND review_correlation_id IS NOT NULL AND reviewed_at IS NOT NULL AND journal_entry_id IS NOT NULL AND settled_at IS NOT NULL)
    OR(state='rejected' AND reviewed_by IS NOT NULL AND reviewed_by<>created_by AND review_action='rejected'
      AND review_reason IS NOT NULL AND review_idempotency_key IS NOT NULL AND review_request_hash IS NOT NULL
      AND review_correlation_id IS NOT NULL AND reviewed_at IS NOT NULL AND journal_entry_id IS NULL AND settled_at IS NULL)
    OR(state='cancelled' AND reviewed_by=created_by AND review_action='cancelled'
      AND review_reason IS NOT NULL AND review_idempotency_key IS NOT NULL AND review_request_hash IS NOT NULL
      AND review_correlation_id IS NOT NULL AND reviewed_at IS NOT NULL AND journal_entry_id IS NULL AND settled_at IS NULL)
  )
);
CREATE INDEX idx_savings_withdrawals_member
  ON savings_withdrawals(organization_id,member_id,enrolment_id,created_at DESC);
CREATE INDEX idx_savings_withdrawals_review
  ON savings_withdrawals(organization_id,state,created_at);

CREATE TABLE savings_withdrawal_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  withdrawal_id UUID NOT NULL,
  action TEXT NOT NULL CHECK(action IN('requested','approved','rejected','cancelled')),
  actor_id UUID NOT NULL REFERENCES users(id),
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
  request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),
  correlation_id UUID NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK(jsonb_typeof(evidence)='object'),
  occurred_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(withdrawal_id,organization_id) REFERENCES savings_withdrawals(id,organization_id),
  UNIQUE(organization_id,idempotency_key)
);

CREATE OR REPLACE FUNCTION require_savings_withdrawal_engine() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF current_setting('microfams.savings_withdrawal_engine',TRUE) IS DISTINCT FROM 'on' THEN
   RAISE EXCEPTION 'SAVINGS_WITHDRAWAL_ENGINE_REQUIRED';
 END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER savings_withdrawals_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_withdrawals
  FOR EACH ROW EXECUTE FUNCTION require_savings_withdrawal_engine();
CREATE TRIGGER savings_withdrawal_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON savings_withdrawal_events
  FOR EACH ROW EXECUTE FUNCTION require_savings_withdrawal_engine();

CREATE OR REPLACE FUNCTION request_savings_withdrawal(
 p_organization UUID,p_actor UUID,p_enrolment UUID,p_amount_minor BIGINT,
 p_idempotency_key TEXT,p_correlation_id UUID,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 v_enrolment savings_enrolments; v_version savings_product_versions; v_existing savings_withdrawals;
 v_withdrawal savings_withdrawals; v_wallet user_wallets; v_wallet_account financial_accounts;
 v_hash TEXT; v_is_early BOOLEAN; v_fee BIGINT:=0; v_principal_balance BIGINT; v_return_balance BIGINT;
 v_principal_reserved BIGINT; v_return_reserved BIGINT; v_principal_available BIGINT; v_return_available BIGINT;
 v_principal_withdrawn BIGINT:=0; v_return_withdrawn BIGINT:=0; v_return_forfeited BIGINT:=0;
BEGIN
 IF p_amount_minor IS NULL OR p_amount_minor<=0 THEN RAISE EXCEPTION 'Withdrawal amount must be positive minor units'; END IF;
 IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_correlation_id IS NULL THEN
   RAISE EXCEPTION 'Withdrawal command identity is invalid';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM organization_memberships
   WHERE organization_id=p_organization AND user_id=p_actor AND status='active') THEN
   RAISE EXCEPTION 'Actor is not an active organization member';
 END IF;
 v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_enrolment::TEXT,
   p_amount_minor::TEXT,p_correlation_id::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-withdrawal:'||p_enrolment::TEXT,0));
 SELECT * INTO v_existing FROM savings_withdrawals
   WHERE organization_id=p_organization AND creation_idempotency_key=p_idempotency_key;
 IF v_existing.id IS NOT NULL THEN
   IF v_existing.creation_request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key reused with different withdrawal facts'; END IF;
   RETURN to_jsonb(v_existing);
 END IF;
 SELECT * INTO v_enrolment FROM savings_enrolments
   WHERE id=p_enrolment AND organization_id=p_organization AND member_id=p_actor AND state IN('active','locked') FOR UPDATE;
 IF v_enrolment.id IS NULL THEN RAISE EXCEPTION 'Savings enrolment is unavailable for withdrawal'; END IF;
 SELECT * INTO v_version FROM savings_product_versions
   WHERE id=v_enrolment.product_version_id AND organization_id=p_organization;
 IF v_version.id IS NULL THEN RAISE EXCEPTION 'Savings product version is unavailable'; END IF;
 IF COALESCE(v_version.eligibility->>'requiredIdentityTier','none')='nin_verified'
   AND NOT EXISTS(SELECT 1 FROM users WHERE id=p_actor AND nin_verified) THEN
   RAISE EXCEPTION 'Verified identity is required for this savings withdrawal';
 END IF;
 v_is_early:=v_enrolment.lock_expires_at IS NOT NULL AND p_at<v_enrolment.lock_expires_at;
 IF v_is_early AND v_version.early_withdrawal_rule='blocked' THEN RAISE EXCEPTION 'Early withdrawal is blocked by the accepted product rules'; END IF;
 IF v_is_early AND v_version.early_withdrawal_rule='fee' THEN v_fee:=v_version.early_withdrawal_fee_minor; END IF;
 IF p_amount_minor<=v_fee THEN RAISE EXCEPTION 'Withdrawal amount must exceed the disclosed fee'; END IF;

 SELECT * INTO v_wallet FROM user_wallets
   WHERE organization_id=p_organization AND user_id=p_actor AND status='ACTIVE' FOR UPDATE;
 IF v_wallet.id IS NULL OR NOT wallet_cutover_is_active(p_organization) THEN RAISE EXCEPTION 'Active destination wallet is unavailable'; END IF;
 SELECT account.* INTO v_wallet_account FROM wallet_ledger_migration_items item
 JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=item.migration_run_id
   AND cutover.organization_id=item.organization_id AND cutover.status='active'
 JOIN financial_accounts account ON account.id=item.financial_account_id AND account.organization_id=item.organization_id
 WHERE item.organization_id=p_organization AND item.source_type='wallet' AND item.source_id=v_wallet.id
   AND account.owner_type='user' AND account.owner_id=p_actor AND account.currency=v_enrolment.currency
   AND account.purpose='individual_wallet_funds' AND account.status='active' FOR UPDATE OF account;
 IF v_wallet_account.id IS NULL THEN RAISE EXCEPTION 'Canonical destination wallet account is unavailable'; END IF;

 v_principal_balance:=GREATEST(wallet_account_balance_minor(v_enrolment.principal_account_id),0);
 v_return_balance:=GREATEST(wallet_account_balance_minor(v_enrolment.accrued_return_account_id),0);
 SELECT COALESCE(sum(principal_withdrawn_minor),0)::BIGINT,
   COALESCE(sum(return_withdrawn_minor+return_forfeited_minor),0)::BIGINT
 INTO v_principal_reserved,v_return_reserved FROM savings_withdrawals
 WHERE organization_id=p_organization AND enrolment_id=p_enrolment AND state='pending_approval';
 v_principal_available:=GREATEST(v_principal_balance-v_principal_reserved,0);
 v_return_available:=GREATEST(v_return_balance-v_return_reserved,0);
 IF v_is_early AND v_version.early_withdrawal_rule='forfeit_returns' THEN
   IF p_amount_minor>v_principal_available THEN RAISE EXCEPTION 'Insufficient available savings principal'; END IF;
   v_principal_withdrawn:=p_amount_minor;
   v_return_forfeited:=v_return_available;
 ELSE
   IF p_amount_minor>v_principal_available+v_return_available THEN RAISE EXCEPTION 'Insufficient available savings balance'; END IF;
   v_return_withdrawn:=LEAST(p_amount_minor,v_return_available);
   v_principal_withdrawn:=p_amount_minor-v_return_withdrawn;
 END IF;
 PERFORM set_config('microfams.savings_withdrawal_engine','on',TRUE);
 INSERT INTO savings_withdrawals(organization_id,enrolment_id,product_version_id,member_id,destination_wallet_id,
   destination_account_id,principal_account_id,accrued_return_account_id,currency,requested_minor,
   principal_withdrawn_minor,return_withdrawn_minor,return_forfeited_minor,fee_minor,net_payout_minor,is_early,
   lock_expires_at_snapshot,early_withdrawal_rule,disclosure_version,disclosure_hash,allocation_version,
   principal_balance_snapshot_minor,return_balance_snapshot_minor,created_by,creation_idempotency_key,
   creation_request_hash,creation_correlation_id,created_at)
 VALUES(p_organization,v_enrolment.id,v_version.id,p_actor,v_wallet.id,v_wallet_account.id,
   v_enrolment.principal_account_id,v_enrolment.accrued_return_account_id,v_enrolment.currency,p_amount_minor,
   v_principal_withdrawn,v_return_withdrawn,v_return_forfeited,v_fee,p_amount_minor-v_fee,v_is_early,
   v_enrolment.lock_expires_at,v_version.early_withdrawal_rule,v_enrolment.accepted_disclosure_version,
   v_enrolment.accepted_disclosure_hash,'returns_then_principal_v1',v_principal_balance,v_return_balance,
   p_actor,p_idempotency_key,v_hash,p_correlation_id,p_at) RETURNING * INTO v_withdrawal;
 INSERT INTO savings_withdrawal_events(organization_id,withdrawal_id,action,actor_id,idempotency_key,
   request_hash,correlation_id,evidence,occurred_at)
 VALUES(p_organization,v_withdrawal.id,'requested',p_actor,p_idempotency_key,v_hash,p_correlation_id,
   jsonb_build_object('requested_minor',p_amount_minor,'net_payout_minor',v_withdrawal.net_payout_minor,
     'principal_withdrawn_minor',v_principal_withdrawn,'return_withdrawn_minor',v_return_withdrawn,
     'return_forfeited_minor',v_return_forfeited,'fee_minor',v_fee,'is_early',v_is_early,
     'early_withdrawal_rule',v_version.early_withdrawal_rule,'allocation_version','returns_then_principal_v1'),p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,'SAVINGS_WITHDRAWAL_REQUESTED','savings_withdrawal',v_withdrawal.id::TEXT,
   jsonb_build_object('enrolment_id',p_enrolment,'requested_minor',p_amount_minor,'net_payout_minor',v_withdrawal.net_payout_minor,
     'currency',v_enrolment.currency,'is_early',v_is_early,'early_withdrawal_rule',v_version.early_withdrawal_rule),p_at);
 RETURN to_jsonb(v_withdrawal);
END $$;

CREATE OR REPLACE FUNCTION review_savings_withdrawal(
 p_organization UUID,p_actor UUID,p_withdrawal UUID,p_action TEXT,p_reason TEXT,
 p_idempotency_key TEXT,p_correlation_id UUID,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 v_withdrawal savings_withdrawals; v_event savings_withdrawal_events; v_wallet user_wallets;
 v_fee_account financial_accounts; v_forfeit_account financial_accounts; v_hash TEXT; v_reason TEXT:=NULLIF(btrim(p_reason),'');
 v_lines JSONB; v_journal UUID; v_account_hash TEXT;
BEGIN
 IF p_action NOT IN('approve','reject') THEN RAISE EXCEPTION 'Withdrawal review action is invalid'; END IF;
 IF NOT has_financial_permission(p_organization,p_actor,'financial.savings.configure') THEN
   RAISE EXCEPTION 'Missing financial.savings.configure permission';
 END IF;
 IF p_action='reject' AND(v_reason IS NULL OR length(v_reason) NOT BETWEEN 8 AND 1000) THEN
   RAISE EXCEPTION 'Withdrawal rejection reason is invalid';
 END IF;
 IF p_action='approve' AND v_reason IS NOT NULL THEN RAISE EXCEPTION 'Approval does not accept a rejection reason'; END IF;
 IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_correlation_id IS NULL THEN
   RAISE EXCEPTION 'Withdrawal review identity is invalid';
 END IF;
 v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_withdrawal::TEXT,
   p_action,COALESCE(v_reason,''),p_correlation_id::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-withdrawal-review:'||p_withdrawal::TEXT,0));
 SELECT * INTO v_event FROM savings_withdrawal_events
   WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF v_event.id IS NOT NULL THEN
   IF v_event.request_hash<>v_hash OR v_event.withdrawal_id<>p_withdrawal
     OR v_event.action<>(CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END) THEN
     RAISE EXCEPTION 'Idempotency key reused with different withdrawal review facts';
   END IF;
   SELECT * INTO v_withdrawal FROM savings_withdrawals WHERE id=p_withdrawal AND organization_id=p_organization;
   RETURN to_jsonb(v_withdrawal);
 END IF;
 SELECT * INTO v_withdrawal FROM savings_withdrawals
   WHERE id=p_withdrawal AND organization_id=p_organization FOR UPDATE;
 IF v_withdrawal.id IS NULL OR v_withdrawal.state<>'pending_approval' THEN RAISE EXCEPTION 'Withdrawal is not pending approval'; END IF;
 IF v_withdrawal.created_by=p_actor THEN RAISE EXCEPTION 'Maker cannot review their own savings withdrawal'; END IF;
 PERFORM set_config('microfams.savings_withdrawal_engine','on',TRUE);
 IF p_action='reject' THEN
   UPDATE savings_withdrawals SET state='rejected',reviewed_by=p_actor,review_action='rejected',review_reason=v_reason,
     review_idempotency_key=p_idempotency_key,review_request_hash=v_hash,review_correlation_id=p_correlation_id,reviewed_at=p_at
   WHERE id=v_withdrawal.id RETURNING * INTO v_withdrawal;
 ELSE
   IF wallet_account_balance_minor(v_withdrawal.principal_account_id)<v_withdrawal.principal_withdrawn_minor
     OR wallet_account_balance_minor(v_withdrawal.accrued_return_account_id)<
       v_withdrawal.return_withdrawn_minor+v_withdrawal.return_forfeited_minor THEN
     RAISE EXCEPTION 'Savings liability changed before approval';
   END IF;
   SELECT * INTO v_wallet FROM user_wallets WHERE id=v_withdrawal.destination_wallet_id
     AND organization_id=p_organization AND user_id=v_withdrawal.member_id AND status='ACTIVE' FOR UPDATE;
   IF v_wallet.id IS NULL OR NOT wallet_cutover_is_active(p_organization) THEN RAISE EXCEPTION 'Destination wallet is unavailable'; END IF;
   IF NOT EXISTS(SELECT 1 FROM financial_accounts WHERE id=v_withdrawal.destination_account_id
     AND organization_id=p_organization AND owner_type='user' AND owner_id=v_withdrawal.member_id
     AND purpose='individual_wallet_funds' AND status='active') THEN RAISE EXCEPTION 'Destination wallet account is unavailable'; END IF;
   IF v_withdrawal.fee_minor>0 THEN
     SELECT * INTO v_fee_account FROM financial_accounts WHERE organization_id=p_organization
       AND purpose='platform_fee_revenue' AND owner_type='organization' AND owner_id IS NULL
       AND currency=v_withdrawal.currency AND effective_until IS NULL FOR UPDATE;
     IF v_fee_account.id IS NULL THEN
       v_account_hash:=encode(digest(convert_to('savings-withdrawal-fee:'||p_organization::TEXT||':'||v_withdrawal.currency,'UTF8'),'sha256'),'hex');
       INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,
         is_control,status,created_by,purpose,effective_from,provisioning_key,provisioning_hash)
       VALUES(p_organization,'SAV.WDR.FEE.'||v_withdrawal.currency,'Savings withdrawal fee revenue - '||v_withdrawal.currency,
         'revenue','credit',v_withdrawal.currency,'organization',NULL,FALSE,'active',p_actor,
         'platform_fee_revenue',p_at::DATE,'savings-withdrawal-fee:'||v_withdrawal.currency,v_account_hash)
       RETURNING * INTO v_fee_account;
     END IF;
   END IF;
   IF v_withdrawal.return_forfeited_minor>0 THEN
     SELECT * INTO v_forfeit_account FROM financial_accounts WHERE organization_id=p_organization
       AND purpose='savings_forfeited_return_revenue' AND owner_type='organization' AND owner_id IS NULL
       AND currency=v_withdrawal.currency AND effective_until IS NULL FOR UPDATE;
     IF v_forfeit_account.id IS NULL THEN
       v_account_hash:=encode(digest(convert_to('savings-forfeited-return:'||p_organization::TEXT||':'||v_withdrawal.currency,'UTF8'),'sha256'),'hex');
       INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,
         is_control,status,created_by,purpose,effective_from,provisioning_key,provisioning_hash)
       VALUES(p_organization,'SAV.FORF.REV.'||v_withdrawal.currency,'Savings forfeited return revenue - '||v_withdrawal.currency,
         'revenue','credit',v_withdrawal.currency,'organization',NULL,FALSE,'active',p_actor,
         'savings_forfeited_return_revenue',p_at::DATE,'savings-forfeited-return:'||v_withdrawal.currency,v_account_hash)
       RETURNING * INTO v_forfeit_account;
     END IF;
   END IF;
   SELECT jsonb_agg(line ORDER BY line_number) INTO v_lines FROM(
     SELECT 1 line_number,jsonb_build_object('account_id',v_withdrawal.principal_account_id,'line_number',1,
       'side','debit','amount_minor',v_withdrawal.principal_withdrawn_minor,'memo','Savings principal withdrawal') line
       WHERE v_withdrawal.principal_withdrawn_minor>0
     UNION ALL SELECT 2,jsonb_build_object('account_id',v_withdrawal.accrued_return_account_id,'line_number',2,
       'side','debit','amount_minor',v_withdrawal.return_withdrawn_minor+v_withdrawal.return_forfeited_minor,
       'memo','Savings return withdrawal or forfeiture')
       WHERE v_withdrawal.return_withdrawn_minor+v_withdrawal.return_forfeited_minor>0
     UNION ALL SELECT 3,jsonb_build_object('account_id',v_withdrawal.destination_account_id,'line_number',3,
       'side','credit','amount_minor',v_withdrawal.net_payout_minor,'memo','Savings withdrawal to member wallet')
     UNION ALL SELECT 4,jsonb_build_object('account_id',v_fee_account.id,'line_number',4,
       'side','credit','amount_minor',v_withdrawal.fee_minor,'memo','Disclosed early-withdrawal fee')
       WHERE v_withdrawal.fee_minor>0
     UNION ALL SELECT 5,jsonb_build_object('account_id',v_forfeit_account.id,'line_number',5,
       'side','credit','amount_minor',v_withdrawal.return_forfeited_minor,'memo','Disclosed early return forfeiture')
       WHERE v_withdrawal.return_forfeited_minor>0
   ) posting_lines;
   v_journal:=post_financial_journal(p_organization,v_withdrawal.currency,p_at::DATE,'savings.withdrawal',
     v_withdrawal.id::TEXT,p_idempotency_key,v_hash,p_correlation_id,'Approved savings withdrawal',p_actor,v_lines);
   UPDATE savings_withdrawals SET state='settled',reviewed_by=p_actor,review_action='approved',review_reason=NULL,
     review_idempotency_key=p_idempotency_key,review_request_hash=v_hash,review_correlation_id=p_correlation_id,
     reviewed_at=p_at,journal_entry_id=v_journal,settled_at=p_at
   WHERE id=v_withdrawal.id RETURNING * INTO v_withdrawal;
   PERFORM sync_wallet_ledger_cache(p_organization,'user',v_wallet.id,v_withdrawal.destination_account_id);
 END IF;
 INSERT INTO savings_withdrawal_events(organization_id,withdrawal_id,action,actor_id,idempotency_key,
   request_hash,correlation_id,evidence,occurred_at)
 VALUES(p_organization,v_withdrawal.id,CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END,
   p_actor,p_idempotency_key,v_hash,p_correlation_id,
   CASE p_action WHEN 'approve' THEN jsonb_build_object('journal_entry_id',v_journal,'net_payout_minor',v_withdrawal.net_payout_minor,
     'fee_minor',v_withdrawal.fee_minor,'return_forfeited_minor',v_withdrawal.return_forfeited_minor)
   ELSE jsonb_build_object('reason',v_reason) END,p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,CASE p_action WHEN 'approve' THEN 'SAVINGS_WITHDRAWAL_SETTLED' ELSE 'SAVINGS_WITHDRAWAL_REJECTED' END,
   'savings_withdrawal',v_withdrawal.id::TEXT,jsonb_build_object('state',v_withdrawal.state,'reason',v_reason,
     'journal_entry_id',v_journal,'net_payout_minor',v_withdrawal.net_payout_minor,'currency',v_withdrawal.currency),p_at);
 RETURN to_jsonb(v_withdrawal);
END $$;

CREATE OR REPLACE FUNCTION cancel_savings_withdrawal(
 p_organization UUID,p_actor UUID,p_withdrawal UUID,p_reason TEXT,p_idempotency_key TEXT,
 p_correlation_id UUID,p_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_withdrawal savings_withdrawals; v_event savings_withdrawal_events; v_reason TEXT:=btrim(p_reason); v_hash TEXT;
BEGIN
 IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Withdrawal cancellation reason is invalid'; END IF;
 IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_correlation_id IS NULL THEN
   RAISE EXCEPTION 'Withdrawal cancellation identity is invalid';
 END IF;
 v_hash:=encode(digest(convert_to(concat_ws('|',p_organization::TEXT,p_actor::TEXT,p_withdrawal::TEXT,
   'cancel',v_reason,p_correlation_id::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':savings-withdrawal-review:'||p_withdrawal::TEXT,0));
 SELECT * INTO v_event FROM savings_withdrawal_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF v_event.id IS NOT NULL THEN
   IF v_event.request_hash<>v_hash OR v_event.withdrawal_id<>p_withdrawal OR v_event.action<>'cancelled' THEN
     RAISE EXCEPTION 'Idempotency key reused with different cancellation facts';
   END IF;
   SELECT * INTO v_withdrawal FROM savings_withdrawals WHERE id=p_withdrawal AND organization_id=p_organization;
   RETURN to_jsonb(v_withdrawal);
 END IF;
 SELECT * INTO v_withdrawal FROM savings_withdrawals WHERE id=p_withdrawal AND organization_id=p_organization
   AND member_id=p_actor FOR UPDATE;
 IF v_withdrawal.id IS NULL OR v_withdrawal.state<>'pending_approval' THEN RAISE EXCEPTION 'Withdrawal is not cancellable'; END IF;
 PERFORM set_config('microfams.savings_withdrawal_engine','on',TRUE);
 UPDATE savings_withdrawals SET state='cancelled',reviewed_by=p_actor,review_action='cancelled',review_reason=v_reason,
   review_idempotency_key=p_idempotency_key,review_request_hash=v_hash,review_correlation_id=p_correlation_id,reviewed_at=p_at
 WHERE id=v_withdrawal.id RETURNING * INTO v_withdrawal;
 INSERT INTO savings_withdrawal_events(organization_id,withdrawal_id,action,actor_id,idempotency_key,
   request_hash,correlation_id,evidence,occurred_at)
 VALUES(p_organization,v_withdrawal.id,'cancelled',p_actor,p_idempotency_key,v_hash,p_correlation_id,
   jsonb_build_object('reason',v_reason),p_at);
 INSERT INTO organization_audit_log(organization_id,actor_id,action,resource_type,resource_id,after_value,occurred_at)
 VALUES(p_organization,p_actor,'SAVINGS_WITHDRAWAL_CANCELLED','savings_withdrawal',v_withdrawal.id::TEXT,
   jsonb_build_object('reason',v_reason,'requested_minor',v_withdrawal.requested_minor,'currency',v_withdrawal.currency),p_at);
 RETURN to_jsonb(v_withdrawal);
END $$;

CREATE OR REPLACE FUNCTION list_member_savings_withdrawals(p_organization UUID,p_actor UUID,p_enrolment UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path=public AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM savings_enrolments WHERE id=p_enrolment AND organization_id=p_organization AND member_id=p_actor) THEN
   RAISE EXCEPTION 'Savings enrolment not found';
 END IF;
 RETURN COALESCE((SELECT jsonb_agg(to_jsonb(w) ORDER BY w.created_at DESC) FROM savings_withdrawals w
   WHERE w.organization_id=p_organization AND w.enrolment_id=p_enrolment AND w.member_id=p_actor),'[]'::JSONB);
END $$;

CREATE OR REPLACE FUNCTION list_savings_withdrawal_reviews(p_organization UUID,p_actor UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path=public AS $$
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.savings.configure') THEN
   RAISE EXCEPTION 'Missing financial.savings.configure permission';
 END IF;
 RETURN COALESCE((SELECT jsonb_agg(to_jsonb(w) ORDER BY w.created_at DESC) FROM savings_withdrawals w
   WHERE w.organization_id=p_organization),'[]'::JSONB);
END $$;

ALTER TABLE savings_withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_withdrawal_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON savings_withdrawals,savings_withdrawal_events FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON savings_withdrawals,savings_withdrawal_events FROM service_role;
GRANT SELECT ON savings_withdrawals,savings_withdrawal_events TO service_role;
REVOKE ALL ON FUNCTION request_savings_withdrawal(UUID,UUID,UUID,BIGINT,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION review_savings_withdrawal(UUID,UUID,UUID,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION cancel_savings_withdrawal(UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_member_savings_withdrawals(UUID,UUID,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION list_savings_withdrawal_reviews(UUID,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION request_savings_withdrawal(UUID,UUID,UUID,BIGINT,TEXT,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION review_savings_withdrawal(UUID,UUID,UUID,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION cancel_savings_withdrawal(UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION list_member_savings_withdrawals(UUID,UUID,UUID) TO service_role;
GRANT EXECUTE ON FUNCTION list_savings_withdrawal_reviews(UUID,UUID) TO service_role;
