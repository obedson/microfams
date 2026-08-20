-- ESC-04: independent release-request decisions without money movement.
SET search_path=public,extensions;
ALTER TABLE escrow_release_requests ADD COLUMN decided_by UUID REFERENCES users(id),ADD COLUMN decision_reason TEXT,ADD COLUMN decided_at TIMESTAMPTZ,ADD COLUMN decision_key TEXT,ADD COLUMN decision_hash VARCHAR(64);
ALTER TABLE escrow_release_requests ADD CONSTRAINT escrow_release_decision_evidence CHECK((state='pending' AND decided_by IS NULL AND decision_reason IS NULL AND decided_at IS NULL AND decision_key IS NULL AND decision_hash IS NULL) OR(state IN('approved','rejected','cancelled') AND decided_by IS NOT NULL AND length(btrim(decision_reason)) BETWEEN 3 AND 500 AND decided_at IS NOT NULL AND length(decision_key) BETWEEN 8 AND 160 AND decision_hash~'^[a-f0-9]{64}$'));
CREATE UNIQUE INDEX uq_escrow_release_decision_key ON escrow_release_requests(organization_id,decision_key) WHERE decision_key IS NOT NULL;
CREATE OR REPLACE FUNCTION decide_escrow_release(p_organization UUID,p_actor UUID,p_request UUID,p_decision TEXT,p_reason TEXT,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r escrow_release_requests;c escrow_contracts;h TEXT;
BEGIN
 IF p_decision NOT IN('approve','reject') OR length(btrim(p_reason)) NOT BETWEEN 3 AND 500 OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 OR p_at IS NULL THEN RAISE EXCEPTION 'Escrow release decision evidence is invalid';END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_request,p_decision,btrim(p_reason)),'UTF8'),'sha256'),'hex');
 SELECT * INTO r FROM escrow_release_requests WHERE organization_id=p_organization AND decision_key=p_idempotency_key;
 IF r.id IS NOT NULL THEN IF r.decision_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different escrow release decision facts';END IF;RETURN to_jsonb(r);END IF;
 SELECT * INTO r FROM escrow_release_requests WHERE id=p_request AND organization_id=p_organization FOR UPDATE;
 IF r.id IS NULL OR r.state<>'pending' THEN RAISE EXCEPTION 'Escrow release request is not pending';END IF;
 SELECT * INTO c FROM escrow_contracts WHERE id=r.contract_id AND organization_id=p_organization FOR UPDATE;
 IF c.state<>'release_pending' THEN RAISE EXCEPTION 'Escrow contract is not awaiting a release decision';END IF;
 IF p_actor=r.requested_by THEN RAISE EXCEPTION 'Escrow release requires independent decision';END IF;
 IF NOT(c.authorized_arbiters @> jsonb_build_array(p_actor::TEXT)) THEN RAISE EXCEPTION 'Actor is not an authorized escrow arbiter';END IF;
 IF p_decision='approve' AND r.amount_minor>c.amount_minor THEN RAISE EXCEPTION 'Escrow release exceeds funded contract amount';END IF;
 PERFORM set_config('microfams.escrow_contract_engine','on',TRUE);
 UPDATE escrow_release_requests SET state=CASE p_decision WHEN 'approve' THEN 'approved' ELSE 'rejected' END,decided_by=p_actor,decision_reason=btrim(p_reason),decided_at=p_at,decision_key=p_idempotency_key,decision_hash=h WHERE id=r.id RETURNING * INTO r;
 IF p_decision='reject' THEN UPDATE escrow_contracts SET state='funded',updated_at=p_at WHERE id=c.id;END IF;
 RETURN to_jsonb(r);
END $$;
REVOKE ALL ON FUNCTION decide_escrow_release(UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION decide_escrow_release(UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
