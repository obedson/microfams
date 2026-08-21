-- ESC-09: independent escrow dispute resolution evidence without money movement.
SET search_path=public,extensions;
ALTER TABLE escrow_disputes ADD COLUMN resolved_by UUID REFERENCES users(id), ADD COLUMN resolution_reason TEXT, ADD COLUMN resolution_key TEXT, ADD COLUMN resolution_hash VARCHAR(64);
ALTER TABLE escrow_disputes ADD CONSTRAINT escrow_dispute_resolution_evidence CHECK ((state='open' AND resolved_by IS NULL AND resolution_reason IS NULL AND resolved_at IS NULL AND resolution_key IS NULL AND resolution_hash IS NULL) OR (state IN('resolved','withdrawn') AND resolved_by IS NOT NULL AND length(btrim(resolution_reason)) BETWEEN 3 AND 1000 AND resolved_at IS NOT NULL AND length(resolution_key) BETWEEN 8 AND 160 AND resolution_hash~'^[a-f0-9]{64}$'));
CREATE UNIQUE INDEX uq_escrow_dispute_resolution_key ON escrow_disputes(organization_id,resolution_key) WHERE resolution_key IS NOT NULL;
CREATE OR REPLACE FUNCTION resolve_escrow_dispute(p_organization UUID,p_actor UUID,p_dispute UUID,p_reason TEXT,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE d escrow_disputes; c escrow_contracts; h TEXT;
BEGIN
 IF p_at IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 1000 OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Escrow dispute resolution evidence is invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_dispute,btrim(p_reason)),'UTF8'),'sha256'),'hex');
 SELECT * INTO d FROM escrow_disputes WHERE organization_id=p_organization AND resolution_key=p_idempotency_key;
 IF d.id IS NOT NULL THEN IF d.resolution_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different escrow resolution facts'; END IF; RETURN to_jsonb(d); END IF;
 SELECT * INTO d FROM escrow_disputes WHERE id=p_dispute AND organization_id=p_organization FOR UPDATE;
 IF d.id IS NULL OR d.state<>'open' THEN RAISE EXCEPTION 'Escrow dispute is not open'; END IF;
 SELECT * INTO c FROM escrow_contracts WHERE id=d.contract_id AND organization_id=p_organization FOR UPDATE;
 IF c.state<>'disputed' OR NOT(c.authorized_arbiters @> jsonb_build_array(p_actor::TEXT)) OR p_actor=d.opened_by THEN RAISE EXCEPTION 'Only an independent authorized arbiter may resolve escrow dispute'; END IF;
 PERFORM set_config('microfams.escrow_contract_engine','on',TRUE);
 UPDATE escrow_disputes SET state='resolved',resolved_by=p_actor,resolution_reason=btrim(p_reason),resolved_at=p_at,resolution_key=p_idempotency_key,resolution_hash=h WHERE id=d.id RETURNING * INTO d;
 UPDATE escrow_contracts SET state='resolved',updated_at=p_at WHERE id=c.id;
 INSERT INTO escrow_dispute_events(organization_id,contract_id,dispute_id,event_type,actor_id,payload,correlation_id,occurred_at) VALUES(p_organization,c.id,d.id,'resolved',p_actor,jsonb_build_object('state','resolved','reason',d.resolution_reason),gen_random_uuid(),p_at);
 RETURN to_jsonb(d);
END $$;
REVOKE ALL ON FUNCTION resolve_escrow_dispute(UUID,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC; GRANT EXECUTE ON FUNCTION resolve_escrow_dispute(UUID,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ) TO service_role;
