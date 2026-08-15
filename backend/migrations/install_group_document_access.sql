-- GT-10B permission-checked group document access
SET search_path=public,extensions;
CREATE TABLE IF NOT EXISTS group_document_access_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), document_id UUID NOT NULL REFERENCES group_documents(id),
 version_id UUID NOT NULL REFERENCES group_document_versions(id), actor_id UUID NOT NULL REFERENCES users(id),
 event_type TEXT NOT NULL CHECK(event_type='DOWNLOAD_URL_AUTHORIZED'), correlation_id UUID NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL, metadata JSONB NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(metadata)='object'),
 occurred_at TIMESTAMPTZ NOT NULL, UNIQUE(organization_id,correlation_id)
);
CREATE OR REPLACE FUNCTION protect_group_document_access_event() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'GROUP_DOCUMENT_ACCESS_EVIDENCE_IMMUTABLE'; END $$;
DROP TRIGGER IF EXISTS protect_group_document_access_event ON group_document_access_events;
CREATE TRIGGER protect_group_document_access_event BEFORE UPDATE OR DELETE ON group_document_access_events FOR EACH ROW EXECUTE FUNCTION protect_group_document_access_event();
ALTER TABLE group_document_access_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON group_document_access_events FOR SELECT USING(has_active_organization_membership(organization_id));
REVOKE ALL ON group_document_access_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_document_access_events TO service_role;
CREATE OR REPLACE FUNCTION authorize_group_document_download(p_organization UUID,p_group UUID,p_actor UUID,p_version UUID,p_correlation UUID,p_expires_at TIMESTAMPTZ,p_at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE d group_documents; v group_document_versions; m organization_memberships; permitted BOOLEAN:=FALSE; visibility TEXT; filename TEXT; BEGIN
 SELECT * INTO m FROM organization_memberships WHERE organization_id=p_organization AND user_id=p_actor AND status='active';
 IF m.id IS NULL THEN RAISE EXCEPTION 'GROUP_DOCUMENT_ACCESS_DENIED'; END IF;
 SELECT dv.* INTO v FROM group_document_versions dv JOIN group_documents gd ON gd.id=dv.document_id
 WHERE dv.id=p_version AND dv.organization_id=p_organization AND dv.group_id=p_group AND dv.state='approved';
 IF v.id IS NULL THEN RAISE EXCEPTION 'GROUP_DOCUMENT_VERSION_NOT_FOUND'; END IF;
 SELECT * INTO d FROM group_documents WHERE id=v.document_id AND organization_id=p_organization AND group_id=p_group;
 visibility:=COALESCE(d.access_policy->>'visibility','private');
 permitted:=p_actor=d.owner_user_id OR m.role='owner' OR m.permissions@>ARRAY['groups.documents.manage'];
 IF NOT permitted AND visibility='members' THEN
  permitted:=EXISTS(SELECT 1 FROM group_members gm WHERE gm.organization_id=p_organization AND gm.group_id=p_group AND gm.user_id=p_actor AND gm.status='active' AND gm.is_active=TRUE);
 END IF;
 IF NOT permitted AND jsonb_typeof(d.access_policy->'allowed_permissions')='array' THEN
  permitted:=EXISTS(SELECT 1 FROM jsonb_array_elements_text(d.access_policy->'allowed_permissions') x WHERE x.value=ANY(m.permissions));
 END IF;
 IF NOT permitted THEN RAISE EXCEPTION 'GROUP_DOCUMENT_ACCESS_DENIED'; END IF;
 IF p_expires_at<=p_at_time OR p_expires_at>p_at_time+INTERVAL '15 minutes' THEN RAISE EXCEPTION 'GROUP_DOCUMENT_ACCESS_EXPIRY_INVALID'; END IF;
 filename:=regexp_replace(v.storage_key,'^.*/','');
 INSERT INTO group_document_access_events(organization_id,group_id,document_id,version_id,actor_id,event_type,correlation_id,expires_at,metadata,occurred_at)
 VALUES(p_organization,p_group,d.id,v.id,p_actor,'DOWNLOAD_URL_AUTHORIZED',p_correlation,p_expires_at,jsonb_build_object('classification',d.classification,'version',v.version),p_at_time);
 RETURN jsonb_build_object('storage_key',v.storage_key,'filename',filename,'media_type',v.media_type,'expires_at',p_expires_at);
END $$;
REVOKE ALL ON FUNCTION authorize_group_document_download(UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION authorize_group_document_download(UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ,TIMESTAMPTZ) TO service_role;
