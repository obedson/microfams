-- ESC-02: exactly-once internal-wallet escrow funding.
SET search_path=public,extensions;

ALTER TABLE escrow_contracts
  ADD COLUMN escrow_account_id UUID UNIQUE REFERENCES financial_accounts(id),
  ADD COLUMN funding_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),
  ADD COLUMN funded_at TIMESTAMPTZ;
DO $$
DECLARE constraint_name TEXT;
BEGIN
 SELECT conname INTO constraint_name FROM pg_constraint
 WHERE conrelid='escrow_contracts'::regclass AND contype='c'
   AND pg_get_constraintdef(oid) LIKE '%awaiting_funding%approved_by%';
 IF constraint_name IS NULL THEN RAISE EXCEPTION 'ESC02: prior lifecycle constraint is unavailable'; END IF;
 EXECUTE format('ALTER TABLE escrow_contracts DROP CONSTRAINT %I',constraint_name);
END $$;
ALTER TABLE escrow_contracts ADD CONSTRAINT escrow_contracts_lifecycle_evidence CHECK (
 (state='draft' AND approved_by IS NULL AND approved_at IS NULL AND escrow_account_id IS NULL AND funding_journal_entry_id IS NULL AND funded_at IS NULL)
 OR (state='awaiting_funding' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND escrow_account_id IS NULL AND funding_journal_entry_id IS NULL AND funded_at IS NULL)
 OR (state IN ('funded','active','release_pending','released','disputed','cancelled','refunded','resolved')
     AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND escrow_account_id IS NOT NULL AND funding_journal_entry_id IS NOT NULL AND funded_at IS NOT NULL)
);

CREATE TABLE escrow_fundings (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, contract_id UUID NOT NULL,
 payer_id UUID NOT NULL REFERENCES users(id), source_wallet_id UUID NOT NULL REFERENCES user_wallets(id),
 source_account_id UUID NOT NULL REFERENCES financial_accounts(id), escrow_account_id UUID NOT NULL REFERENCES financial_accounts(id),
 currency VARCHAR(3) NOT NULL CHECK(currency~'^[A-Z]{3}$'), amount_minor BIGINT NOT NULL CHECK(amount_minor>0),
 journal_entry_id UUID NOT NULL UNIQUE REFERENCES journal_entries(id), idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
 request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL, funded_at TIMESTAMPTZ NOT NULL,
 FOREIGN KEY(contract_id,organization_id) REFERENCES escrow_contracts(id,organization_id), UNIQUE(organization_id,idempotency_key), UNIQUE(contract_id)
);
CREATE TRIGGER escrow_fundings_engine_only BEFORE INSERT OR UPDATE OR DELETE ON escrow_fundings FOR EACH ROW EXECUTE FUNCTION require_escrow_contract_engine();

CREATE OR REPLACE FUNCTION fund_escrow_contract_from_wallet(p_organization UUID,p_actor UUID,p_contract UUID,p_idempotency_key TEXT,p_correlation_id UUID,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE c escrow_contracts; old escrow_fundings; funding escrow_fundings; w user_wallets; source financial_accounts; escrow_account financial_accounts; holds BIGINT; available BIGINT; h TEXT; lines JSONB; journal UUID; code TEXT;
BEGIN
 IF p_correlation_id IS NULL OR p_at IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Escrow funding command evidence is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active') THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
 SELECT * INTO c FROM escrow_contracts WHERE id=p_contract AND organization_id=p_organization FOR UPDATE;
 IF c.id IS NULL OR c.payer_id<>p_actor THEN RAISE EXCEPTION 'Escrow contract is unavailable to this payer'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_contract,c.currency,c.amount_minor,p_correlation_id),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':escrow-funding:'||p_idempotency_key,0));
 SELECT * INTO old FROM escrow_fundings WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF old.id IS NOT NULL THEN IF old.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different escrow funding facts'; END IF; RETURN to_jsonb(old); END IF;
 IF c.state<>'awaiting_funding' OR p_at>=c.expires_at THEN RAISE EXCEPTION 'Escrow contract is not eligible for funding'; END IF;
 SELECT * INTO w FROM user_wallets WHERE organization_id=p_organization AND user_id=p_actor AND status='ACTIVE' FOR UPDATE;
 IF w.id IS NULL OR NOT wallet_cutover_is_active(p_organization) THEN RAISE EXCEPTION 'Active ledger wallet is unavailable'; END IF;
 SELECT account.* INTO source FROM wallet_ledger_migration_items item
 JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=item.migration_run_id AND cutover.organization_id=item.organization_id AND cutover.status='active'
 JOIN financial_accounts account ON account.id=item.financial_account_id AND account.organization_id=item.organization_id
 WHERE item.organization_id=p_organization AND item.source_type='wallet' AND item.source_id=w.id
   AND account.owner_type='user' AND account.owner_id=p_actor AND account.currency=c.currency
   AND account.purpose='individual_wallet_funds' AND account.status='active' FOR UPDATE OF account;
 IF source.id IS NULL THEN RAISE EXCEPTION 'Canonical payer wallet account is unavailable'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':wallet-source:'||source.id::TEXT,0));
 SELECT COALESCE(sum(amount_minor),0)::BIGINT INTO holds FROM fund_reservations WHERE organization_id=p_organization AND wallet_account_id=source.id AND state='active' AND expires_at>p_at;
 available:=wallet_account_balance_minor(source.id)-holds;
 IF available<c.amount_minor THEN RAISE EXCEPTION 'Insufficient available wallet funds'; END IF;
 SELECT * INTO escrow_account FROM financial_accounts WHERE organization_id=p_organization AND purpose='escrow_funds_held' AND owner_type='escrow_contract' AND owner_id=c.id AND currency=c.currency AND effective_until IS NULL FOR UPDATE;
 IF escrow_account.id IS NULL THEN
   code:='ESC.'||upper(substr(md5(c.id::TEXT),1,24));
   INSERT INTO financial_accounts(organization_id,code,name,account_class,normal_side,currency,owner_type,owner_id,is_control,status,created_by,purpose,effective_from,provisioning_key,provisioning_hash)
   VALUES(p_organization,code,'Escrow funds held','liability','credit',c.currency,'escrow_contract',c.id,TRUE,'active',p_actor,'escrow_funds_held',p_at::DATE,'escrow-account:'||c.id,encode(digest(convert_to(p_organization::TEXT||'|'||c.id::TEXT||'|'||c.currency,'UTF8'),'sha256'),'hex')) RETURNING * INTO escrow_account;
 END IF;
 lines:=jsonb_build_array(
  jsonb_build_object('account_id',source.id,'line_number',1,'side','debit','amount_minor',c.amount_minor,'memo','Fund escrow from payer wallet'),
  jsonb_build_object('account_id',escrow_account.id,'line_number',2,'side','credit','amount_minor',c.amount_minor,'memo','Hold funded escrow liability'));
 journal:=post_financial_journal(p_organization,c.currency,p_at::DATE,'escrow.funding',c.id::TEXT,p_idempotency_key,h,p_correlation_id,'Fund escrow contract',p_actor,lines);
 PERFORM set_config('microfams.escrow_contract_engine','on',TRUE);
 INSERT INTO escrow_fundings(organization_id,contract_id,payer_id,source_wallet_id,source_account_id,escrow_account_id,currency,amount_minor,journal_entry_id,idempotency_key,request_hash,correlation_id,funded_at)
 VALUES(p_organization,c.id,p_actor,w.id,source.id,escrow_account.id,c.currency,c.amount_minor,journal,p_idempotency_key,h,p_correlation_id,p_at) RETURNING * INTO funding;
 UPDATE escrow_contracts SET state='funded',escrow_account_id=escrow_account.id,funding_journal_entry_id=journal,funded_at=p_at,updated_at=p_at WHERE id=c.id;
 INSERT INTO escrow_contract_events VALUES(gen_random_uuid(),p_organization,c.id,'funded',p_actor,p_idempotency_key||':event',h,jsonb_build_object('amount_minor',c.amount_minor,'currency',c.currency,'journal_entry_id',journal),p_at);
 PERFORM sync_wallet_ledger_cache(p_organization,'user',w.id,source.id);
 RETURN to_jsonb(funding);
END $$;

ALTER TABLE escrow_contract_events DROP CONSTRAINT escrow_contract_events_action_check;
ALTER TABLE escrow_contract_events ADD CONSTRAINT escrow_contract_events_action_check CHECK(action IN ('created','activated','funded'));
ALTER TABLE escrow_fundings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON escrow_fundings FROM anon,authenticated; REVOKE INSERT,UPDATE,DELETE ON escrow_fundings FROM service_role; GRANT SELECT ON escrow_fundings TO service_role;
REVOKE ALL ON FUNCTION fund_escrow_contract_from_wallet(UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fund_escrow_contract_from_wallet(UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) TO service_role;
