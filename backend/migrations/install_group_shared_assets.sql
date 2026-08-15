-- GT-10C tenant-scoped shared-asset registry and custody foundation
SET search_path=public,extensions;
CREATE TABLE IF NOT EXISTS group_shared_assets (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), asset_key TEXT NOT NULL CHECK(asset_key~'^[a-z][a-z0-9_]{2,63}$'),
 name TEXT NOT NULL CHECK(char_length(trim(name)) BETWEEN 2 AND 200),
 category TEXT NOT NULL CHECK(category~'^[a-z][a-z0-9_]{1,63}$'),
 acquisition_source JSONB NOT NULL CHECK(jsonb_typeof(acquisition_source)='object' AND COALESCE(acquisition_source->>'type','') IN('purchase','donation','project','transfer','opening','other')),
 custodian_member_id UUID NOT NULL REFERENCES group_members(id),
 location JSONB NOT NULL CHECK(jsonb_typeof(location)='object'),
 condition_state TEXT NOT NULL CHECK(condition_state IN('new','good','fair','poor','damaged')),
 availability_state TEXT NOT NULL DEFAULT 'available' CHECK(availability_state IN('available','reserved','checked_out','maintenance','unavailable')),
 valuation_metadata JSONB NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(valuation_metadata)='object'),
 depreciation_metadata JSONB NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(depreciation_metadata)='object'),
 maintenance_schedule JSONB NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(maintenance_schedule)='object'),
 lifecycle_state TEXT NOT NULL DEFAULT 'active' CHECK(lifecycle_state IN('active','disposed','lost','transferred')),
 evidence_refs JSONB NOT NULL CHECK(jsonb_typeof(evidence_refs)='array' AND jsonb_array_length(evidence_refs)>0),
 created_by UUID NOT NULL REFERENCES users(id), idempotency_key TEXT NOT NULL,
 acquired_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 UNIQUE(organization_id,group_id,asset_key), UNIQUE(organization_id,idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_group_shared_assets_tenant ON group_shared_assets(organization_id,group_id,lifecycle_state,availability_state);
CREATE TABLE IF NOT EXISTS group_shared_asset_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), asset_id UUID NOT NULL REFERENCES group_shared_assets(id),
 actor_id UUID REFERENCES users(id), event_type TEXT NOT NULL CHECK(event_type='ASSET_REGISTERED'),
 correlation_id UUID NOT NULL, evidence JSONB NOT NULL CHECK(jsonb_typeof(evidence)='object'),
 occurred_at TIMESTAMPTZ NOT NULL, UNIQUE(organization_id,correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_group_shared_asset_events_asset ON group_shared_asset_events(organization_id,group_id,asset_id,occurred_at);
CREATE OR REPLACE FUNCTION protect_group_shared_asset_evidence() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF current_setting('microfams.group_shared_asset_engine',TRUE)='on' THEN RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END; END IF;
 RAISE EXCEPTION 'GROUP_SHARED_ASSET_ENGINE_REQUIRED';
END $$;
DROP TRIGGER IF EXISTS protect_group_shared_asset_evidence ON group_shared_assets;
CREATE TRIGGER protect_group_shared_asset_evidence BEFORE INSERT OR UPDATE OR DELETE ON group_shared_assets FOR EACH ROW EXECUTE FUNCTION protect_group_shared_asset_evidence();
DROP TRIGGER IF EXISTS protect_group_shared_asset_evidence ON group_shared_asset_events;
CREATE TRIGGER protect_group_shared_asset_evidence BEFORE INSERT OR UPDATE OR DELETE ON group_shared_asset_events FOR EACH ROW EXECUTE FUNCTION protect_group_shared_asset_evidence();
CREATE OR REPLACE FUNCTION group_shared_asset_actor_permitted(o UUID,a UUID) RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM organization_memberships m WHERE m.organization_id=o AND m.user_id=a AND m.status='active' AND (m.role='owner' OR m.permissions@>ARRAY['groups.assets.manage'])); $$;
ALTER TABLE group_shared_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_shared_asset_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON group_shared_assets FOR SELECT USING(has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON group_shared_asset_events FOR SELECT USING(has_active_organization_membership(organization_id));
REVOKE ALL ON group_shared_assets,group_shared_asset_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_shared_assets,group_shared_asset_events TO service_role;
CREATE OR REPLACE FUNCTION register_group_shared_asset(o UUID,g UUID,a UUID,k TEXT,asset_name TEXT,category_name TEXT,source JSONB,custodian UUID,location_data JSONB,condition_name TEXT,valuation JSONB,depreciation JSONB,maintenance JSONB,evidence JSONB,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE asset_id UUID; existing group_shared_assets; BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-shared-asset:'||idem,0));
 SELECT * INTO existing FROM group_shared_assets WHERE organization_id=o AND idempotency_key=idem;
 IF existing.id IS NOT NULL THEN
  IF existing.group_id<>g OR existing.asset_key<>k OR existing.name<>trim(asset_name) OR existing.category<>category_name
   OR existing.acquisition_source<>source OR existing.custodian_member_id<>custodian OR existing.location<>location_data
   OR existing.condition_state<>condition_name OR existing.valuation_metadata<>valuation
   OR existing.depreciation_metadata<>depreciation OR existing.maintenance_schedule<>maintenance
   OR existing.evidence_refs<>evidence
  THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN existing.id;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM groups WHERE id=g AND organization_id=o AND lifecycle_state='active') THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_ACTIVE_GROUP_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_members gm WHERE gm.id=custodian AND gm.organization_id=o AND gm.group_id=g AND gm.status='active' AND gm.is_active=TRUE) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_CUSTODIAN_INVALID'; END IF;
 IF k!~'^[a-z][a-z0-9_]{2,63}$' OR char_length(trim(asset_name)) NOT BETWEEN 2 AND 200 OR category_name!~'^[a-z][a-z0-9_]{1,63}$'
  OR jsonb_typeof(source)<>'object' OR COALESCE(source->>'type','') NOT IN('purchase','donation','project','transfer','opening','other')
  OR jsonb_typeof(location_data)<>'object' OR condition_name NOT IN('new','good','fair','poor','damaged')
  OR jsonb_typeof(valuation)<>'object' OR jsonb_typeof(depreciation)<>'object' OR jsonb_typeof(maintenance)<>'object'
  OR jsonb_typeof(evidence)<>'array' OR jsonb_array_length(evidence)=0 OR char_length(trim(COALESCE(idem,'')))<8
 THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_COMMAND_INVALID'; END IF;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 INSERT INTO group_shared_assets(organization_id,group_id,asset_key,name,category,acquisition_source,custodian_member_id,location,condition_state,valuation_metadata,depreciation_metadata,maintenance_schedule,evidence_refs,created_by,idempotency_key,acquired_at,created_at,updated_at)
 VALUES(o,g,k,trim(asset_name),category_name,source,custodian,location_data,condition_name,valuation,depreciation,maintenance,evidence,a,idem,at_time,at_time,at_time) RETURNING id INTO asset_id;
 INSERT INTO group_shared_asset_events(organization_id,group_id,asset_id,actor_id,event_type,correlation_id,evidence,occurred_at)
 VALUES(o,g,asset_id,a,'ASSET_REGISTERED',corr,jsonb_build_object('acquisition_source',source,'custodian_member_id',custodian,'evidence_refs',evidence),at_time);
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN asset_id;
END $$;
REVOKE ALL ON FUNCTION group_shared_asset_actor_permitted(UUID,UUID),register_group_shared_asset(UUID,UUID,UUID,TEXT,TEXT,TEXT,JSONB,UUID,JSONB,TEXT,JSONB,JSONB,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION register_group_shared_asset(UUID,UUID,UUID,TEXT,TEXT,TEXT,JSONB,UUID,JSONB,TEXT,JSONB,JSONB,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) TO service_role;
