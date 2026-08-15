-- GT-10A governed group document versioning
SET search_path=public,extensions;
CREATE TABLE IF NOT EXISTS group_documents (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), document_key TEXT NOT NULL CHECK(document_key~'^[a-z][a-z0-9_]{2,63}$'),
 classification TEXT NOT NULL CHECK(classification IN('constitution','minutes','contract','financial_report','decision_evidence','general')),
 owner_user_id UUID NOT NULL REFERENCES users(id), access_policy JSONB NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(access_policy)='object'),
 retention_class TEXT NOT NULL CHECK(char_length(trim(retention_class)) BETWEEN 2 AND 64),
 legal_hold_status TEXT NOT NULL DEFAULT 'none' CHECK(legal_hold_status IN('none','active','released')),
 current_version_id UUID, created_by UUID NOT NULL REFERENCES users(id), idempotency_key TEXT NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 UNIQUE(organization_id,group_id,document_key), UNIQUE(organization_id,idempotency_key)
);
CREATE TABLE IF NOT EXISTS group_document_versions (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), document_id UUID NOT NULL REFERENCES group_documents(id),
 version INTEGER NOT NULL CHECK(version>0), state TEXT NOT NULL DEFAULT 'draft' CHECK(state IN('draft','approved')),
 storage_key TEXT NOT NULL CHECK(char_length(storage_key) BETWEEN 10 AND 500),
 checksum_sha256 TEXT NOT NULL CHECK(checksum_sha256~'^[0-9a-f]{64}$'),
 media_type TEXT NOT NULL CHECK(char_length(trim(media_type)) BETWEEN 3 AND 100),
 byte_size BIGINT NOT NULL CHECK(byte_size>=0), correction_of_version_id UUID REFERENCES group_document_versions(id),
 proposal_id UUID REFERENCES group_proposals(id), created_by UUID NOT NULL REFERENCES users(id),
 approved_by UUID REFERENCES users(id), approved_at TIMESTAMPTZ, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 UNIQUE(document_id,version), UNIQUE(organization_id,storage_key), UNIQUE(proposal_id),
 CHECK((state='approved')=(approved_at IS NOT NULL AND approved_by IS NOT NULL AND proposal_id IS NOT NULL))
);
ALTER TABLE group_documents DROP CONSTRAINT IF EXISTS group_documents_current_version_id_fkey;
ALTER TABLE group_documents ADD CONSTRAINT group_documents_current_version_id_fkey FOREIGN KEY(current_version_id) REFERENCES group_document_versions(id);
CREATE TABLE IF NOT EXISTS group_document_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), document_id UUID NOT NULL REFERENCES group_documents(id),
 version_id UUID REFERENCES group_document_versions(id), actor_id UUID REFERENCES users(id),
 event_type TEXT NOT NULL CHECK(event_type IN('DOCUMENT_CREATED','DOCUMENT_VERSION_DRAFTED','DOCUMENT_VERSION_APPROVED')),
 proposal_id UUID REFERENCES group_proposals(id), correlation_id UUID NOT NULL, evidence JSONB NOT NULL DEFAULT '{}',
 occurred_at TIMESTAMPTZ NOT NULL, UNIQUE(organization_id,correlation_id)
);
CREATE OR REPLACE FUNCTION protect_group_document_evidence() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='group_document_events' AND TG_OP<>'INSERT' THEN RAISE EXCEPTION 'GROUP_DOCUMENT_EVIDENCE_IMMUTABLE'; END IF;
 IF TG_TABLE_NAME='group_document_versions' AND TG_OP IN('UPDATE','DELETE') THEN
  IF OLD.state='approved' THEN RAISE EXCEPTION 'GROUP_DOCUMENT_APPROVED_VERSION_IMMUTABLE'; END IF;
 END IF;
 IF current_setting('microfams.group_document_engine',TRUE)='on' THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
 RAISE EXCEPTION 'GROUP_DOCUMENT_ENGINE_REQUIRED';
END $$;
DO $$ DECLARE t TEXT; BEGIN FOREACH t IN ARRAY ARRAY['group_documents','group_document_versions','group_document_events'] LOOP
 EXECUTE format('DROP TRIGGER IF EXISTS protect_group_document_evidence ON %I',t);
 EXECUTE format('CREATE TRIGGER protect_group_document_evidence BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION protect_group_document_evidence()',t); END LOOP; END $$;
CREATE OR REPLACE FUNCTION group_document_actor_permitted(o UUID,a UUID) RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM organization_memberships m WHERE m.organization_id=o AND m.user_id=a AND m.status='active' AND (m.role='owner' OR m.permissions@>ARRAY['groups.documents.manage'])); $$;
ALTER TABLE group_documents ENABLE ROW LEVEL SECURITY; ALTER TABLE group_document_versions ENABLE ROW LEVEL SECURITY; ALTER TABLE group_document_events ENABLE ROW LEVEL SECURITY;
DO $$ DECLARE t TEXT; BEGIN FOREACH t IN ARRAY ARRAY['group_documents','group_document_versions','group_document_events'] LOOP
 EXECUTE format('CREATE POLICY tenant_read ON %I FOR SELECT USING(has_active_organization_membership(organization_id))',t);
 EXECUTE format('REVOKE ALL ON %I FROM PUBLIC,anon,authenticated',t); EXECUTE format('GRANT SELECT ON %I TO service_role',t); END LOOP; END $$;
CREATE OR REPLACE FUNCTION create_group_document(o UUID,g UUID,a UUID,k TEXT,class_name TEXT,owner_id UUID,policy JSONB,retention TEXT,storage TEXT,checksum TEXT,mime TEXT,size_bytes BIGINT,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE document_id UUID; version_id UUID; existing UUID; BEGIN
 IF NOT group_document_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_DOCUMENT_PERMISSION_DENIED'; END IF;
 SELECT id INTO existing FROM group_documents WHERE organization_id=o AND idempotency_key=idem; IF existing IS NOT NULL THEN RETURN existing; END IF;
 IF NOT EXISTS(SELECT 1 FROM groups WHERE id=g AND organization_id=o AND lifecycle_state='active') THEN RAISE EXCEPTION 'GROUP_DOCUMENT_ACTIVE_GROUP_REQUIRED'; END IF;
 IF k!~'^[a-z][a-z0-9_]{2,63}$' OR class_name NOT IN('constitution','minutes','contract','financial_report','decision_evidence','general') OR jsonb_typeof(policy)<>'object' OR char_length(trim(retention)) NOT BETWEEN 2 AND 64 OR checksum!~'^[0-9a-f]{64}$' OR size_bytes<0 OR position(o::TEXT||'/'||g::TEXT||'/' IN storage)<>1 THEN RAISE EXCEPTION 'GROUP_DOCUMENT_COMMAND_INVALID'; END IF;
 IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=o AND user_id=owner_id AND status='active') THEN RAISE EXCEPTION 'GROUP_DOCUMENT_OWNER_INVALID'; END IF;
 PERFORM set_config('microfams.group_document_engine','on',TRUE);
 INSERT INTO group_documents(organization_id,group_id,document_key,classification,owner_user_id,access_policy,retention_class,created_by,idempotency_key,created_at,updated_at) VALUES(o,g,k,class_name,owner_id,policy,trim(retention),a,idem,at_time,at_time) RETURNING id INTO document_id;
 INSERT INTO group_document_versions(organization_id,group_id,document_id,version,storage_key,checksum_sha256,media_type,byte_size,created_by,created_at) VALUES(o,g,document_id,1,storage,checksum,mime,size_bytes,a,at_time) RETURNING id INTO version_id;
 INSERT INTO group_document_events(organization_id,group_id,document_id,version_id,actor_id,event_type,correlation_id,occurred_at) VALUES(o,g,document_id,version_id,a,'DOCUMENT_CREATED',corr,at_time);
 RETURN document_id;
END $$;
CREATE OR REPLACE FUNCTION draft_group_document_correction(o UUID,g UUID,a UUID,document_id UUID,storage TEXT,checksum TEXT,mime TEXT,size_bytes BIGINT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE d group_documents; version_id UUID; next_version INTEGER; BEGIN
 IF NOT group_document_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_DOCUMENT_PERMISSION_DENIED'; END IF;
 SELECT * INTO d FROM group_documents WHERE id=document_id AND organization_id=o AND group_id=g FOR UPDATE;
 IF d.id IS NULL OR d.current_version_id IS NULL OR checksum!~'^[0-9a-f]{64}$' OR size_bytes<0 OR position(o::TEXT||'/'||g::TEXT||'/' IN storage)<>1 THEN RAISE EXCEPTION 'GROUP_DOCUMENT_CORRECTION_INVALID'; END IF;
 SELECT COALESCE(max(version),0)+1 INTO next_version FROM group_document_versions WHERE group_document_versions.document_id=draft_group_document_correction.document_id;
 PERFORM set_config('microfams.group_document_engine','on',TRUE);
 INSERT INTO group_document_versions(organization_id,group_id,document_id,version,storage_key,checksum_sha256,media_type,byte_size,correction_of_version_id,created_by,created_at) VALUES(o,g,d.id,next_version,storage,checksum,mime,size_bytes,d.current_version_id,a,at_time) RETURNING id INTO version_id;
 INSERT INTO group_document_events(organization_id,group_id,document_id,version_id,actor_id,event_type,correlation_id,evidence,occurred_at) VALUES(o,g,d.id,version_id,a,'DOCUMENT_VERSION_DRAFTED',corr,jsonb_build_object('correction_of_version_id',d.current_version_id),at_time);
 RETURN version_id;
END $$;
CREATE OR REPLACE FUNCTION approve_group_document_version(o UUID,g UUID,a UUID,document_id UUID,version_id UUID,proposal_id UUID,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE d group_documents; v group_document_versions; q group_proposals; BEGIN
 IF NOT group_document_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_DOCUMENT_PERMISSION_DENIED'; END IF;
 SELECT * INTO d FROM group_documents WHERE id=document_id AND organization_id=o AND group_id=g FOR UPDATE;
 SELECT * INTO v FROM group_document_versions WHERE id=version_id AND group_document_versions.document_id=approve_group_document_version.document_id AND organization_id=o FOR UPDATE;
 SELECT * INTO q FROM group_proposals WHERE id=proposal_id AND organization_id=o AND group_id=g;
 IF d.id IS NULL OR v.id IS NULL OR v.state<>'draft' OR q.id IS NULL OR q.state<>'approved' OR q.proposal_type<>'document_publication' OR q.execution_payload->>'document_key'<>d.document_key OR a=v.created_by OR a=q.proposer_id OR ((d.current_version_id IS NULL)<>(v.correction_of_version_id IS NULL)) OR (d.current_version_id IS NOT NULL AND v.correction_of_version_id<>d.current_version_id) THEN RAISE EXCEPTION 'GROUP_DOCUMENT_APPROVAL_REQUIRED'; END IF;
 PERFORM set_config('microfams.group_document_engine','on',TRUE);
 UPDATE group_document_versions SET state='approved',proposal_id=q.id,approved_by=a,approved_at=at_time WHERE id=v.id;
 UPDATE group_documents SET current_version_id=v.id,updated_at=at_time WHERE id=d.id;
 INSERT INTO group_document_events(organization_id,group_id,document_id,version_id,actor_id,event_type,proposal_id,correlation_id,evidence,occurred_at) VALUES(o,g,d.id,v.id,a,'DOCUMENT_VERSION_APPROVED',q.id,corr,jsonb_build_object('version',v.version,'checksum_sha256',v.checksum_sha256),at_time);
 RETURN v.id;
END $$;
REVOKE ALL ON FUNCTION group_document_actor_permitted(UUID,UUID),create_group_document(UUID,UUID,UUID,TEXT,TEXT,UUID,JSONB,TEXT,TEXT,TEXT,TEXT,BIGINT,TEXT,UUID,TIMESTAMPTZ),draft_group_document_correction(UUID,UUID,UUID,UUID,TEXT,TEXT,TEXT,BIGINT,UUID,TIMESTAMPTZ),approve_group_document_version(UUID,UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION create_group_document(UUID,UUID,UUID,TEXT,TEXT,UUID,JSONB,TEXT,TEXT,TEXT,TEXT,BIGINT,TEXT,UUID,TIMESTAMPTZ),draft_group_document_correction(UUID,UUID,UUID,UUID,TEXT,TEXT,TEXT,BIGINT,UUID,TIMESTAMPTZ),approve_group_document_version(UUID,UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ) TO service_role;
