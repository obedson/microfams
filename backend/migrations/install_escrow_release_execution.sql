-- ESC-05: exactly-once approved internal-wallet release execution.
SET search_path=public,extensions;
ALTER TABLE escrow_release_requests ADD COLUMN release_journal_entry_id UUID UNIQUE REFERENCES journal_entries(id),ADD COLUMN released_at TIMESTAMPTZ;
ALTER TABLE escrow_contracts ADD COLUMN released_minor BIGINT NOT NULL DEFAULT 0 CHECK(released_minor>=0 AND released_minor<=amount_minor);
CREATE OR REPLACE FUNCTION execute_escrow_release(p_organization UUID,p_actor UUID,p_request UUID,p_correlation UUID,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r escrow_release_requests;c escrow_contracts;w user_wallets;a financial_accounts;j UUID;h TEXT;new_total BIGINT;
BEGIN
 IF p_correlation IS NULL OR p_at IS NULL THEN RAISE EXCEPTION 'Escrow release execution evidence is invalid';END IF;
 SELECT * INTO r FROM escrow_release_requests WHERE id=p_request AND organization_id=p_organization FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Escrow release request is unavailable';END IF;
 IF r.release_journal_entry_id IS NOT NULL THEN RETURN to_jsonb(r);END IF;
 IF r.state<>'approved' THEN RAISE EXCEPTION 'Escrow release request is not approved';END IF;
 SELECT * INTO c FROM escrow_contracts WHERE id=r.contract_id AND organization_id=p_organization FOR UPDATE;
 IF c.state<>'release_pending' OR c.escrow_account_id IS NULL THEN RAISE EXCEPTION 'Escrow contract is not ready for release';END IF;
 IF NOT(c.authorized_arbiters @> jsonb_build_array(p_actor::TEXT)) OR p_actor<>r.decided_by THEN RAISE EXCEPTION 'Only the approving arbiter may execute escrow release';END IF;
 new_total:=c.released_minor+r.amount_minor;
 IF new_total>c.amount_minor OR wallet_account_balance_minor(c.escrow_account_id)<r.amount_minor THEN RAISE EXCEPTION 'Escrow release exceeds held funds';END IF;
 SELECT * INTO w FROM user_wallets WHERE organization_id=p_organization AND user_id=c.beneficiary_id AND status='ACTIVE' FOR UPDATE;
 SELECT account.* INTO a FROM wallet_ledger_migration_items i JOIN wallet_ledger_cutovers cutover ON cutover.migration_run_id=i.migration_run_id AND cutover.organization_id=i.organization_id AND cutover.status='active' JOIN financial_accounts account ON account.id=i.financial_account_id AND account.organization_id=i.organization_id WHERE i.organization_id=p_organization AND i.source_type='wallet' AND i.source_id=w.id AND account.owner_type='user' AND account.owner_id=c.beneficiary_id AND account.currency=c.currency AND account.purpose='individual_wallet_funds' AND account.status='active' FOR UPDATE OF account;
 IF w.id IS NULL OR a.id IS NULL THEN RAISE EXCEPTION 'Beneficiary ledger wallet is unavailable';END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_request,r.amount_minor,p_correlation),'UTF8'),'sha256'),'hex');
 j:=post_financial_journal(p_organization,c.currency,p_at::DATE,'escrow.release',r.id::TEXT,'escrow-release-'||r.id::TEXT,h,p_correlation,'Release approved escrow milestone',p_actor,jsonb_build_array(jsonb_build_object('account_id',c.escrow_account_id,'line_number',1,'side','debit','amount_minor',r.amount_minor),jsonb_build_object('account_id',a.id,'line_number',2,'side','credit','amount_minor',r.amount_minor)));
 PERFORM set_config('microfams.escrow_contract_engine','on',TRUE);
 UPDATE escrow_release_requests SET release_journal_entry_id=j,released_at=p_at WHERE id=r.id RETURNING * INTO r;
 UPDATE escrow_contracts SET released_minor=new_total,state=CASE WHEN new_total=amount_minor THEN 'released' ELSE 'active' END,updated_at=p_at WHERE id=c.id;
 PERFORM sync_wallet_ledger_cache(p_organization,'user',w.id,a.id);
 RETURN to_jsonb(r);
END $$;
REVOKE ALL ON FUNCTION execute_escrow_release(UUID,UUID,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION execute_escrow_release(UUID,UUID,UUID,UUID,TIMESTAMPTZ) TO service_role;
