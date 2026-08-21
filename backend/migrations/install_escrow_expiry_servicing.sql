-- ESC-08: fail-closed escrow expiry servicing with immutable evidence.
SET search_path=public,extensions;
ALTER TABLE escrow_contracts DROP CONSTRAINT escrow_contracts_lifecycle_evidence;
ALTER TABLE escrow_contracts ADD CONSTRAINT escrow_contracts_lifecycle_evidence CHECK (
 (state='draft' AND approved_by IS NULL AND approved_at IS NULL AND escrow_account_id IS NULL AND funding_journal_entry_id IS NULL AND funded_at IS NULL)
 OR (state='awaiting_funding' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND escrow_account_id IS NULL AND funding_journal_entry_id IS NULL AND funded_at IS NULL)
 OR (state='cancelled' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND ((escrow_account_id IS NULL AND funding_journal_entry_id IS NULL AND funded_at IS NULL) OR (escrow_account_id IS NOT NULL AND funding_journal_entry_id IS NOT NULL AND funded_at IS NOT NULL)))
 OR (state IN ('funded','active','release_pending','released','disputed','refunded','resolved') AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND escrow_account_id IS NOT NULL AND funding_journal_entry_id IS NOT NULL AND funded_at IS NOT NULL)
);
ALTER TABLE escrow_contract_events DROP CONSTRAINT escrow_contract_events_action_check;
ALTER TABLE escrow_contract_events ADD CONSTRAINT escrow_contract_events_action_check CHECK(action IN ('created','activated','funded','expired'));
CREATE OR REPLACE FUNCTION expire_escrow_contract(p_organization UUID,p_actor UUID,p_contract UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE c escrow_contracts; e escrow_contract_events; h TEXT;
BEGIN
 IF p_at IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Escrow expiry evidence is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_contract,p_idempotency_key),'UTF8'),'sha256'),'hex');
 SELECT * INTO e FROM escrow_contract_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF e.id IS NOT NULL THEN IF e.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different escrow expiry facts'; END IF; SELECT * INTO c FROM escrow_contracts WHERE id=e.contract_id; RETURN to_jsonb(c); END IF;
 SELECT * INTO c FROM escrow_contracts WHERE id=p_contract AND organization_id=p_organization FOR UPDATE;
 IF c.id IS NULL OR c.state NOT IN ('awaiting_funding','funded','active','release_pending') OR p_at<c.expires_at THEN RAISE EXCEPTION 'Escrow contract is not eligible for expiry'; END IF;
 IF c.state IN ('funded','active','release_pending') AND (c.escrow_account_id IS NULL OR wallet_account_balance_minor(c.escrow_account_id)<>0) THEN RAISE EXCEPTION 'Funded escrow requires approved settlement before expiry'; END IF;
 PERFORM set_config('microfams.escrow_contract_engine','on',TRUE);
 UPDATE escrow_contracts SET state='cancelled',updated_at=p_at WHERE id=c.id RETURNING * INTO c;
 INSERT INTO escrow_contract_events VALUES(gen_random_uuid(),p_organization,c.id,'expired',p_actor,p_idempotency_key,h,jsonb_build_object('state','cancelled','expired_at',p_at),p_at);
 RETURN to_jsonb(c);
END $$;
REVOKE ALL ON FUNCTION expire_escrow_contract(UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION expire_escrow_contract(UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
