-- ESC-06: idempotent escrow dispute opening and release freeze.
SET search_path=public,extensions;
CREATE TABLE escrow_disputes (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, contract_id UUID NOT NULL,
 opened_by UUID NOT NULL REFERENCES users(id), reason_code TEXT NOT NULL CHECK(length(btrim(reason_code)) BETWEEN 3 AND 80),
 narrative TEXT NOT NULL CHECK(length(btrim(narrative)) BETWEEN 20 AND 2000), state TEXT NOT NULL DEFAULT 'open' CHECK(state IN('open','resolved','withdrawn')),
 idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160), request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),
 correlation_id UUID NOT NULL, opened_at TIMESTAMPTZ NOT NULL, resolved_at TIMESTAMPTZ,
 FOREIGN KEY(contract_id,organization_id) REFERENCES escrow_contracts(id,organization_id), UNIQUE(organization_id,idempotency_key), UNIQUE(contract_id),
 CHECK((state='open' AND resolved_at IS NULL) OR (state IN('resolved','withdrawn') AND resolved_at IS NOT NULL))
);
CREATE TABLE escrow_dispute_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, contract_id UUID NOT NULL,
 dispute_id UUID NOT NULL REFERENCES escrow_disputes(id), event_type TEXT NOT NULL CHECK(event_type IN('opened','resolved','withdrawn')),
 actor_id UUID NOT NULL REFERENCES users(id), payload JSONB NOT NULL CHECK(jsonb_typeof(payload)='object'), correlation_id UUID NOT NULL, occurred_at TIMESTAMPTZ NOT NULL
);
CREATE TRIGGER escrow_disputes_engine_only BEFORE INSERT OR UPDATE OR DELETE ON escrow_disputes FOR EACH ROW EXECUTE FUNCTION require_escrow_contract_engine();
CREATE TRIGGER escrow_dispute_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON escrow_dispute_events FOR EACH ROW EXECUTE FUNCTION require_escrow_contract_engine();
CREATE OR REPLACE FUNCTION open_escrow_dispute(p_organization UUID,p_actor UUID,p_contract UUID,p_reason_code TEXT,p_narrative TEXT,p_idempotency_key TEXT,p_correlation_id UUID,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE c escrow_contracts; d escrow_disputes; h TEXT;
BEGIN
 IF p_correlation_id IS NULL OR p_at IS NULL OR length(btrim(p_reason_code)) NOT BETWEEN 3 AND 80 OR length(btrim(p_narrative)) NOT BETWEEN 20 AND 2000 OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Escrow dispute evidence is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active') THEN RAISE EXCEPTION 'Actor is not an active organization member'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_contract,btrim(p_reason_code),btrim(p_narrative),p_correlation_id),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':escrow-dispute:'||p_idempotency_key,0));
 SELECT * INTO d FROM escrow_disputes WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF d.id IS NOT NULL THEN IF d.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different escrow dispute facts'; END IF; RETURN to_jsonb(d); END IF;
 SELECT * INTO c FROM escrow_contracts WHERE id=p_contract AND organization_id=p_organization FOR UPDATE;
 IF c.id IS NULL OR c.state NOT IN('funded','active','release_pending') THEN RAISE EXCEPTION 'Escrow contract is not eligible for dispute'; END IF;
 IF p_actor<>c.payer_id AND p_actor<>c.beneficiary_id AND NOT(c.authorized_arbiters @> jsonb_build_array(p_actor::TEXT)) THEN RAISE EXCEPTION 'Actor is not authorized to open escrow dispute'; END IF;
 PERFORM set_config('microfams.escrow_contract_engine','on',TRUE);
 INSERT INTO escrow_disputes(organization_id,contract_id,opened_by,reason_code,narrative,idempotency_key,request_hash,correlation_id,opened_at) VALUES(p_organization,p_contract,p_actor,btrim(p_reason_code),btrim(p_narrative),p_idempotency_key,h,p_correlation_id,p_at) RETURNING * INTO d;
 UPDATE escrow_contracts SET state='disputed',updated_at=p_at WHERE id=c.id;
 INSERT INTO escrow_dispute_events(organization_id,contract_id,dispute_id,event_type,actor_id,payload,correlation_id,occurred_at) VALUES(p_organization,p_contract,d.id,'opened',p_actor,jsonb_build_object('reason_code',d.reason_code,'state','disputed'),p_correlation_id,p_at);
 RETURN to_jsonb(d);
END $$;
ALTER TABLE escrow_disputes ENABLE ROW LEVEL SECURITY; ALTER TABLE escrow_dispute_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON escrow_disputes,escrow_dispute_events FROM anon,authenticated; REVOKE INSERT,UPDATE,DELETE ON escrow_disputes,escrow_dispute_events FROM service_role; GRANT SELECT ON escrow_disputes,escrow_dispute_events TO service_role;
REVOKE ALL ON FUNCTION open_escrow_dispute(UUID,UUID,UUID,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC; GRANT EXECUTE ON FUNCTION open_escrow_dispute(UUID,UUID,UUID,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ) TO service_role;
