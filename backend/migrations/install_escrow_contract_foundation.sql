-- ESC-01: immutable tenant-scoped escrow contract terms and governed activation.
SET search_path = public, extensions;

CREATE TABLE escrow_contracts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
  payer_id UUID NOT NULL REFERENCES users(id), beneficiary_id UUID NOT NULL REFERENCES users(id),
  currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'), amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  purpose TEXT NOT NULL CHECK (length(btrim(purpose)) BETWEEN 3 AND 240),
  milestones JSONB NOT NULL CHECK (jsonb_typeof(milestones)='array' AND jsonb_array_length(milestones)>0),
  release_rules JSONB NOT NULL CHECK (jsonb_typeof(release_rules)='object'),
  authorized_arbiters JSONB NOT NULL CHECK (jsonb_typeof(authorized_arbiters)='array' AND jsonb_array_length(authorized_arbiters)>0),
  dispute_window_ends_at TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL,
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','awaiting_funding','funded','active','release_pending','released','disputed','cancelled','refunded','resolved')),
  created_by UUID NOT NULL REFERENCES users(id), approved_by UUID REFERENCES users(id), approved_at TIMESTAMPTZ,
  creation_key TEXT NOT NULL CHECK (length(creation_key) BETWEEN 8 AND 160), creation_hash VARCHAR(64) NOT NULL CHECK (creation_hash ~ '^[a-f0-9]{64}$'),
  created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL,
  UNIQUE(organization_id, creation_key), UNIQUE(id, organization_id), CHECK (payer_id<>beneficiary_id),
  CHECK (expires_at>dispute_window_ends_at),
  CHECK ((state='awaiting_funding' AND approved_by IS NOT NULL AND approved_at IS NOT NULL) OR state='draft')
);
CREATE TABLE escrow_contract_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL, contract_id UUID NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('created','activated')), actor_id UUID NOT NULL REFERENCES users(id),
  idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 160), request_hash VARCHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  evidence JSONB NOT NULL CHECK(jsonb_typeof(evidence)='object'), occurred_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY(contract_id,organization_id) REFERENCES escrow_contracts(id,organization_id), UNIQUE(organization_id,idempotency_key)
);
CREATE OR REPLACE FUNCTION require_escrow_contract_engine() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
 IF current_setting('microfams.escrow_contract_engine',TRUE)<>'on' THEN RAISE EXCEPTION 'Escrow contract evidence is immutable outside the engine'; END IF;
 RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER escrow_contracts_engine_only BEFORE INSERT OR UPDATE OR DELETE ON escrow_contracts FOR EACH ROW EXECUTE FUNCTION require_escrow_contract_engine();
CREATE TRIGGER escrow_contract_events_engine_only BEFORE INSERT OR UPDATE OR DELETE ON escrow_contract_events FOR EACH ROW EXECUTE FUNCTION require_escrow_contract_engine();

CREATE OR REPLACE FUNCTION create_escrow_contract_draft(p_organization UUID,p_actor UUID,p_payer UUID,p_beneficiary UUID,p_currency TEXT,p_amount_minor BIGINT,p_purpose TEXT,p_milestones JSONB,p_release_rules JSONB,p_authorized_arbiters JSONB,p_dispute_window_ends_at TIMESTAMPTZ,p_expires_at TIMESTAMPTZ,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE c escrow_contracts; h TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.escrow.create') THEN RAISE EXCEPTION 'Missing financial.escrow.create permission'; END IF;
 IF upper(p_currency)!~'^[A-Z]{3}$' OR p_amount_minor<=0 OR p_payer=p_beneficiary OR p_expires_at<=p_dispute_window_ends_at OR jsonb_typeof(p_milestones)<>'array' OR jsonb_array_length(p_milestones)=0 OR jsonb_typeof(p_release_rules)<>'object' OR jsonb_typeof(p_authorized_arbiters)<>'array' OR jsonb_array_length(p_authorized_arbiters)=0 OR length(p_idempotency_key) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'Escrow contract terms are invalid'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_payer,p_beneficiary,upper(p_currency),p_amount_minor,p_purpose,p_milestones,p_release_rules,p_authorized_arbiters,p_dispute_window_ends_at,p_expires_at,p_idempotency_key),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':escrow:'||p_idempotency_key,0));
 SELECT * INTO c FROM escrow_contracts WHERE organization_id=p_organization AND creation_key=p_idempotency_key;
 IF c.id IS NOT NULL THEN IF c.creation_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different escrow facts'; END IF; RETURN to_jsonb(c); END IF;
 PERFORM set_config('microfams.escrow_contract_engine','on',TRUE);
 INSERT INTO escrow_contracts(organization_id,payer_id,beneficiary_id,currency,amount_minor,purpose,milestones,release_rules,authorized_arbiters,dispute_window_ends_at,expires_at,created_by,creation_key,creation_hash,created_at,updated_at)
 VALUES(p_organization,p_payer,p_beneficiary,upper(p_currency),p_amount_minor,btrim(p_purpose),p_milestones,p_release_rules,p_authorized_arbiters,p_dispute_window_ends_at,p_expires_at,p_actor,p_idempotency_key,h,p_at,p_at) RETURNING * INTO c;
 INSERT INTO escrow_contract_events VALUES(gen_random_uuid(),p_organization,c.id,'created',p_actor,p_idempotency_key,h,jsonb_build_object('state','draft'),p_at);
 RETURN to_jsonb(c);
END $$;

CREATE OR REPLACE FUNCTION activate_escrow_contract(p_organization UUID,p_actor UUID,p_contract UUID,p_idempotency_key TEXT,p_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE c escrow_contracts; e escrow_contract_events; h TEXT;
BEGIN
 IF NOT has_financial_permission(p_organization,p_actor,'financial.escrow.create') THEN RAISE EXCEPTION 'Missing financial.escrow.create permission'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',p_organization,p_actor,p_contract,'activate',p_idempotency_key),'UTF8'),'sha256'),'hex');
 SELECT * INTO e FROM escrow_contract_events WHERE organization_id=p_organization AND idempotency_key=p_idempotency_key;
 IF e.id IS NOT NULL THEN IF e.request_hash<>h THEN RAISE EXCEPTION 'Idempotency key reused with different escrow command facts'; END IF; SELECT * INTO c FROM escrow_contracts WHERE id=e.contract_id; RETURN to_jsonb(c); END IF;
 SELECT * INTO c FROM escrow_contracts WHERE id=p_contract AND organization_id=p_organization FOR UPDATE;
 IF c.id IS NULL OR c.state<>'draft' THEN RAISE EXCEPTION 'Escrow contract is not an expected draft'; END IF;
 IF c.created_by=p_actor THEN RAISE EXCEPTION 'Escrow contract requires independent activation'; END IF;
 PERFORM set_config('microfams.escrow_contract_engine','on',TRUE);
 UPDATE escrow_contracts SET state='awaiting_funding',approved_by=p_actor,approved_at=p_at,updated_at=p_at WHERE id=c.id RETURNING * INTO c;
 INSERT INTO escrow_contract_events VALUES(gen_random_uuid(),p_organization,c.id,'activated',p_actor,p_idempotency_key,h,jsonb_build_object('state','awaiting_funding','approved_by',p_actor),p_at);
 RETURN to_jsonb(c);
END $$;

INSERT INTO feature_flags(key,domain,description,default_enabled,failure_mode,risk)
VALUES ('financial.escrow.create','escrow','Create and activate escrow contracts.',FALSE,'closed','regulated')
ON CONFLICT(key) DO NOTHING;
UPDATE organization_memberships SET permissions=ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(permissions,'{}')||ARRAY['financial.escrow.create']) x) WHERE role='owner';
ALTER TABLE escrow_contracts ENABLE ROW LEVEL SECURITY; ALTER TABLE escrow_contract_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON escrow_contracts,escrow_contract_events FROM anon,authenticated;
REVOKE INSERT,UPDATE,DELETE ON escrow_contracts,escrow_contract_events FROM service_role;
GRANT SELECT ON escrow_contracts,escrow_contract_events TO service_role;
REVOKE ALL ON FUNCTION create_escrow_contract_draft(UUID,UUID,UUID,UUID,TEXT,BIGINT,TEXT,JSONB,JSONB,JSONB,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,TIMESTAMPTZ),activate_escrow_contract(UUID,UUID,UUID,TEXT,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_escrow_contract_draft(UUID,UUID,UUID,UUID,TEXT,BIGINT,TEXT,JSONB,JSONB,JSONB,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,TIMESTAMPTZ),activate_escrow_contract(UUID,UUID,UUID,TEXT,TIMESTAMPTZ) TO service_role;
