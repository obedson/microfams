-- GT-10J governed shared-asset disposal proposal foundation.
-- Approval records intent only; execution and journal posting remain disabled.
SET search_path=public,extensions;

CREATE TABLE IF NOT EXISTS group_shared_asset_disposal_requests (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), asset_id UUID NOT NULL REFERENCES group_shared_assets(id),
 disposal_method TEXT NOT NULL CHECK(disposal_method IN('sale','scrap','donation','destruction','other')),
 reason TEXT NOT NULL CHECK(char_length(trim(reason)) BETWEEN 2 AND 2000),
 evidence_refs JSONB NOT NULL CHECK(jsonb_typeof(evidence_refs)='array' AND jsonb_array_length(evidence_refs)>0),
 state TEXT NOT NULL DEFAULT 'draft' CHECK(state IN('draft','proposed','approved','cancelled')),
 proposal_id UUID UNIQUE REFERENCES group_proposals(id), created_by UUID NOT NULL REFERENCES users(id),
 approved_by UUID REFERENCES users(id), approved_at TIMESTAMPTZ, idempotency_key TEXT NOT NULL,
 request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 UNIQUE(organization_id,idempotency_key), UNIQUE(organization_id,correlation_id),
 CHECK((state='approved')=(approved_by IS NOT NULL AND approved_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_group_asset_disposal_requests ON group_shared_asset_disposal_requests(organization_id,group_id,asset_id,state);
CREATE TABLE IF NOT EXISTS group_shared_asset_disposal_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), asset_id UUID NOT NULL REFERENCES group_shared_assets(id),
 disposal_request_id UUID NOT NULL REFERENCES group_shared_asset_disposal_requests(id), actor_id UUID REFERENCES users(id),
 event_type TEXT NOT NULL CHECK(event_type IN('DISPOSAL_REQUESTED','DISPOSAL_SUBMITTED','DISPOSAL_APPROVED')),
 proposal_id UUID REFERENCES group_proposals(id), correlation_id UUID NOT NULL, evidence JSONB NOT NULL DEFAULT '{}',
 occurred_at TIMESTAMPTZ NOT NULL, UNIQUE(organization_id,correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_group_asset_disposal_events ON group_shared_asset_disposal_events(organization_id,group_id,asset_id,occurred_at);
CREATE OR REPLACE FUNCTION protect_group_shared_asset_disposal_evidence() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF current_setting('microfams.group_shared_asset_disposal_engine',TRUE)='on' THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
 RAISE EXCEPTION 'GROUP_SHARED_ASSET_DISPOSAL_ENGINE_REQUIRED';
END $$;
DROP TRIGGER IF EXISTS protect_group_shared_asset_disposal_evidence ON group_shared_asset_disposal_requests;
CREATE TRIGGER protect_group_shared_asset_disposal_evidence BEFORE INSERT OR UPDATE OR DELETE ON group_shared_asset_disposal_requests FOR EACH ROW EXECUTE FUNCTION protect_group_shared_asset_disposal_evidence();
DROP TRIGGER IF EXISTS protect_group_shared_asset_disposal_evidence ON group_shared_asset_disposal_events;
CREATE TRIGGER protect_group_shared_asset_disposal_evidence BEFORE INSERT OR UPDATE OR DELETE ON group_shared_asset_disposal_events FOR EACH ROW EXECUTE FUNCTION protect_group_shared_asset_disposal_evidence();
ALTER TABLE group_shared_asset_disposal_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_shared_asset_disposal_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON group_shared_asset_disposal_requests FOR SELECT USING(has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON group_shared_asset_disposal_events FOR SELECT USING(has_active_organization_membership(organization_id));
REVOKE ALL ON group_shared_asset_disposal_requests,group_shared_asset_disposal_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_shared_asset_disposal_requests,group_shared_asset_disposal_events TO service_role;
CREATE OR REPLACE FUNCTION create_group_shared_asset_disposal(o UUID,g UUID,a UUID,asset UUID,method TEXT,reason_text TEXT,evidence JSONB,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE request_id UUID; existing group_shared_asset_disposal_requests; h TEXT; current_asset group_shared_assets;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,asset,method,trim(reason_text),evidence::TEXT),'UTF8'),'sha256'),'hex');
 SELECT * INTO existing FROM group_shared_asset_disposal_requests WHERE organization_id=o AND idempotency_key=idem;
 IF existing.id IS NOT NULL THEN IF existing.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_IDEMPOTENCY_CONFLICT'; END IF; RETURN existing.id; END IF;
 IF method NOT IN('sale','scrap','donation','destruction','other') OR char_length(trim(COALESCE(reason_text,''))) NOT BETWEEN 2 AND 2000
  OR jsonb_typeof(evidence)<>'array' OR jsonb_array_length(evidence)=0 OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160
 THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_COMMAND_INVALID'; END IF;
 SELECT * INTO current_asset FROM group_shared_assets WHERE id=asset AND organization_id=o AND group_id=g FOR UPDATE;
 IF current_asset.id IS NULL OR current_asset.lifecycle_state<>'active' OR current_asset.availability_state NOT IN('available','unavailable') THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_ASSET_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM group_shared_asset_reservations r WHERE r.asset_id=asset AND r.state IN('requested','confirmed','checked_out')) THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_RESERVATIONS_PENDING'; END IF;
 PERFORM set_config('microfams.group_shared_asset_disposal_engine','on',TRUE);
 INSERT INTO group_shared_asset_disposal_requests(organization_id,group_id,asset_id,disposal_method,reason,evidence_refs,created_by,idempotency_key,request_hash,correlation_id,created_at,updated_at)
 VALUES(o,g,asset,method,trim(reason_text),evidence,a,idem,h,corr,at_time,at_time) RETURNING id INTO request_id;
 INSERT INTO group_shared_asset_disposal_events(organization_id,group_id,asset_id,disposal_request_id,actor_id,event_type,correlation_id,evidence,occurred_at)
 VALUES(o,g,asset,request_id,a,'DISPOSAL_REQUESTED',corr,jsonb_build_object('disposal_method',method,'reason',trim(reason_text),'evidence_refs',evidence),at_time);
 PERFORM set_config('microfams.group_shared_asset_disposal_engine','',TRUE); RETURN request_id;
END $$;
CREATE OR REPLACE FUNCTION submit_group_shared_asset_disposal(o UUID,g UUID,a UUID,request_id UUID,proposal_id UUID,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_disposal_requests; q group_proposals;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 SELECT * INTO r FROM group_shared_asset_disposal_requests WHERE id=request_id AND organization_id=o AND group_id=g FOR UPDATE;
 SELECT * INTO q FROM group_proposals WHERE id=proposal_id AND organization_id=o AND group_id=g;
 IF r.id IS NULL OR r.state<>'draft' OR q.id IS NULL OR q.state NOT IN('draft','open','approved') OR q.proposal_type<>'shared_asset_action'
  OR q.execution_payload->>'action'<>'dispose' OR q.execution_payload->>'asset_id'<>r.asset_id::TEXT OR q.execution_payload->>'disposal_id'<>r.id::TEXT
 THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_PROPOSAL_INVALID'; END IF;
 PERFORM set_config('microfams.group_shared_asset_disposal_engine','on',TRUE);
 UPDATE group_shared_asset_disposal_requests SET state='proposed',proposal_id=q.id,updated_at=at_time WHERE id=r.id;
 INSERT INTO group_shared_asset_disposal_events(organization_id,group_id,asset_id,disposal_request_id,actor_id,event_type,proposal_id,correlation_id,evidence,occurred_at)
 VALUES(o,g,r.asset_id,r.id,a,'DISPOSAL_SUBMITTED',q.id,corr,jsonb_build_object('proposal_id',q.id),at_time);
 PERFORM set_config('microfams.group_shared_asset_disposal_engine','',TRUE); RETURN r.id;
END $$;
CREATE OR REPLACE FUNCTION approve_group_shared_asset_disposal(o UUID,g UUID,a UUID,request_id UUID,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_disposal_requests; q group_proposals; current_asset group_shared_assets;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 SELECT * INTO r FROM group_shared_asset_disposal_requests WHERE id=request_id AND organization_id=o AND group_id=g FOR UPDATE;
 SELECT * INTO q FROM group_proposals WHERE id=r.proposal_id AND organization_id=o AND group_id=g;
 SELECT * INTO current_asset FROM group_shared_assets WHERE id=r.asset_id AND organization_id=o AND group_id=g FOR UPDATE;
 IF r.id IS NULL OR r.state<>'proposed' OR q.id IS NULL OR q.state<>'approved' OR q.proposal_type<>'shared_asset_action'
  OR q.execution_payload->>'action'<>'dispose' OR a=r.created_by OR a=q.proposer_id THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_APPROVAL_REQUIRED'; END IF;
 IF current_asset.id IS NULL OR current_asset.lifecycle_state<>'active' OR current_asset.availability_state NOT IN('available','unavailable')
  OR EXISTS(SELECT 1 FROM group_shared_asset_reservations x WHERE x.asset_id=r.asset_id AND x.state IN('requested','confirmed','checked_out')) THEN RAISE EXCEPTION 'GROUP_ASSET_DISPOSAL_STATE_INVALID'; END IF;
 PERFORM set_config('microfams.group_shared_asset_disposal_engine','on',TRUE);
 UPDATE group_shared_asset_disposal_requests SET state='approved',approved_by=a,approved_at=at_time,updated_at=at_time WHERE id=r.id;
 INSERT INTO group_shared_asset_disposal_events(organization_id,group_id,asset_id,disposal_request_id,actor_id,event_type,proposal_id,correlation_id,evidence,occurred_at)
 VALUES(o,g,r.asset_id,r.id,a,'DISPOSAL_APPROVED',q.id,corr,jsonb_build_object('approval_state','approved','execution_enabled',false),at_time);
 PERFORM set_config('microfams.group_shared_asset_disposal_engine','',TRUE); RETURN r.id;
END $$;
REVOKE ALL ON FUNCTION create_group_shared_asset_disposal(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,TEXT,UUID,TIMESTAMPTZ),submit_group_shared_asset_disposal(UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ),approve_group_shared_asset_disposal(UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION create_group_shared_asset_disposal(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,TEXT,UUID,TIMESTAMPTZ),submit_group_shared_asset_disposal(UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ),approve_group_shared_asset_disposal(UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ) TO service_role;
