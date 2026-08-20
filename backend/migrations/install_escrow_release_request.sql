-- ESC-03: governed release requests without money movement.
SET search_path=public,extensions;
CREATE TABLE escrow_release_requests(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),organization_id UUID NOT NULL,contract_id UUID NOT NULL,
 requested_by UUID NOT NULL REFERENCES users(id),milestone_index INTEGER NOT NULL CHECK(milestone_index>=0),
 amount_minor BIGINT NOT NULL CHECK(amount_minor>0),evidence JSONB NOT NULL CHECK(jsonb_typeof(evidence)='object'),
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN('pending','approved','rejected','cancelled')),
 idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160),
 request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),requested_at TIMESTAMPTZ NOT NULL,
 FOREIGN KEY(contract_id,organization_id) REFERENCES escrow_contracts(id,organization_id),
 UNIQUE(organization_id,idempotency_key),UNIQUE(contract_id,milestone_index)
);
CREATE TRIGGER escrow_release_requests_engine_only BEFORE INSERT OR UPDATE OR DELETE ON escrow_release_requests FOR EACH ROW EXECUTE FUNCTION require_escrow_contract_engine();
CREATE OR REPLACE FUNCTION request_escrow_release(p_organization UUID,p_actor UUID,p_contract UUID,p_milestone_index INTEGER,p_amount_minor BIGINT,p_evidence JSONB,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE c escrow_contracts; old escrow_release_requests; r escrow_release_requests; h TEXT;
BEGIN
 IF p_at IS NULL OR p_milestone_index<0 OR p_amount_minor<=0 OR jsonb_typeof(p_evidence)<>'object' OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Escrow release request evidence is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_contract,p_milestone_index,p_amount_minor,p_evidence),'UTF8'),'sha256'),'hex'); PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':escrow-release:'||p_idempotency_key,0)); SELECT * INTO old FROM escrow_release_requests WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key; IF old.id IS NOT NULL THEN IF old.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different escrow release facts'; END IF; RETURN to_jsonb(old); END IF; SELECT * INTO c FROM escrow_contracts WHERE id=p_contract AND organization_id=p_organization FOR UPDATE;
 IF c.id IS NULL OR c.state NOT IN('funded','active') THEN RAISE EXCEPTION 'Escrow contract is not eligible for release request'; END IF;
 IF p_at>=c.expires_at OR p_milestone_index>=jsonb_array_length(c.milestones) THEN RAISE EXCEPTION 'Escrow release milestone is invalid'; END IF;
 IF p_actor<>c.beneficiary_id AND NOT(c.authorized_arbiters @> jsonb_build_array(p_actor::TEXT)) THEN RAISE EXCEPTION 'Actor is not authorized to request escrow release'; END IF;
 PERFORM set_config('microfams.escrow_contract_engine','on',TRUE);
 INSERT INTO escrow_release_requests(organization_id,contract_id,requested_by,milestone_index,amount_minor,evidence,idempotency_key,request_hash,requested_at)
 VALUES(p_organization,p_contract,p_actor,p_milestone_index,p_amount_minor,p_evidence,p_idempotency_key,h,p_at) RETURNING * INTO r;
 UPDATE escrow_contracts SET state='release_pending',updated_at=p_at WHERE id=c.id;
 RETURN to_jsonb(r);
END $$;
ALTER TABLE escrow_release_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON escrow_release_requests FROM anon,authenticated;REVOKE INSERT,UPDATE,DELETE ON escrow_release_requests FROM service_role;GRANT SELECT ON escrow_release_requests TO service_role;
REVOKE ALL ON FUNCTION request_escrow_release(UUID,UUID,UUID,INTEGER,BIGINT,JSONB,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION request_escrow_release(UUID,UUID,UUID,INTEGER,BIGINT,JSONB,TEXT,TIMESTAMPTZ) TO service_role;
