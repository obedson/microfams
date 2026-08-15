-- GT-10E auditable shared-asset damage and maintenance condition events.
SET search_path=public,extensions;

CREATE TABLE IF NOT EXISTS group_shared_asset_condition_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id),
 asset_id UUID NOT NULL REFERENCES group_shared_assets(id),
 actor_id UUID NOT NULL REFERENCES users(id),
 event_type TEXT NOT NULL CHECK(event_type IN('DAMAGE_REPORTED','MAINTENANCE_STARTED','MAINTENANCE_COMPLETED')),
 related_event_id UUID REFERENCES group_shared_asset_condition_events(id),
 condition_before TEXT NOT NULL CHECK(condition_before IN('new','good','fair','poor','damaged')),
 condition_after TEXT NOT NULL CHECK(condition_after IN('new','good','fair','poor','damaged')),
 availability_before TEXT NOT NULL CHECK(availability_before IN('available','reserved','checked_out','maintenance','unavailable')),
 availability_after TEXT NOT NULL CHECK(availability_after IN('available','reserved','checked_out','maintenance','unavailable')),
 location_snapshot JSONB NOT NULL CHECK(jsonb_typeof(location_snapshot)='object'),
 details JSONB NOT NULL CHECK(jsonb_typeof(details)='object'),
 evidence_refs JSONB NOT NULL CHECK(jsonb_typeof(evidence_refs)='array' AND jsonb_array_length(evidence_refs)>0),
 idempotency_key TEXT NOT NULL CHECK(char_length(trim(idempotency_key)) BETWEEN 8 AND 160),
 request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'),
 correlation_id UUID NOT NULL,
 occurred_at TIMESTAMPTZ NOT NULL,
 UNIQUE(organization_id,idempotency_key),
 UNIQUE(organization_id,correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_group_asset_condition_events_asset ON group_shared_asset_condition_events(organization_id,group_id,asset_id,occurred_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_group_asset_maintenance_completion ON group_shared_asset_condition_events(related_event_id) WHERE event_type='MAINTENANCE_COMPLETED';

DROP TRIGGER IF EXISTS protect_group_shared_asset_evidence ON group_shared_asset_condition_events;
CREATE TRIGGER protect_group_shared_asset_evidence BEFORE INSERT OR UPDATE OR DELETE ON group_shared_asset_condition_events FOR EACH ROW EXECUTE FUNCTION protect_group_shared_asset_evidence();

ALTER TABLE group_shared_asset_condition_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON group_shared_asset_condition_events FOR SELECT USING(has_active_organization_membership(organization_id));
REVOKE ALL ON group_shared_asset_condition_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_shared_asset_condition_events TO service_role;

CREATE OR REPLACE FUNCTION report_group_shared_asset_damage(
 o UUID,g UUID,a UUID,asset UUID,severity_name TEXT,description_text TEXT,location_data JSONB,evidence JSONB,
 idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE current_asset group_shared_assets; prior group_shared_asset_condition_events; event_id UUID; h TEXT;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 IF severity_name NOT IN('minor','major','critical') OR char_length(trim(COALESCE(description_text,''))) NOT BETWEEN 2 AND 2000
  OR jsonb_typeof(location_data)<>'object' OR jsonb_typeof(evidence)<>'array' OR jsonb_array_length(evidence)=0
  OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160
 THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_COMMAND_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,asset,severity_name,trim(description_text),location_data::TEXT,evidence::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-condition:'||idem,0));
 SELECT * INTO prior FROM group_shared_asset_condition_events WHERE organization_id=o AND idempotency_key=idem;
 IF prior.id IS NOT NULL THEN
  IF prior.event_type<>'DAMAGE_REPORTED' OR prior.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN prior.id;
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(asset::TEXT,0));
 SELECT * INTO current_asset FROM group_shared_assets WHERE id=asset AND organization_id=o AND group_id=g FOR UPDATE;
 IF current_asset.id IS NULL OR current_asset.lifecycle_state<>'active' THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_ASSET_INVALID'; END IF;
 IF current_asset.availability_state NOT IN('available','unavailable') THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_ASSET_COMMITTED'; END IF;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_assets SET condition_state='damaged',availability_state='unavailable',location=location_data,updated_at=at_time WHERE id=asset;
 INSERT INTO group_shared_asset_condition_events(organization_id,group_id,asset_id,actor_id,event_type,condition_before,condition_after,availability_before,availability_after,location_snapshot,details,evidence_refs,idempotency_key,request_hash,correlation_id,occurred_at)
 VALUES(o,g,asset,a,'DAMAGE_REPORTED',current_asset.condition_state,'damaged',current_asset.availability_state,'unavailable',location_data,
  jsonb_build_object('severity',severity_name,'description',trim(description_text)),evidence,idem,h,corr,at_time) RETURNING id INTO event_id;
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN event_id;
END $$;

CREATE OR REPLACE FUNCTION start_group_shared_asset_maintenance(
 o UUID,g UUID,a UUID,asset UUID,work_description TEXT,provider_data JSONB,location_data JSONB,evidence JSONB,
 idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE current_asset group_shared_assets; prior group_shared_asset_condition_events; event_id UUID; h TEXT;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 IF char_length(trim(COALESCE(work_description,''))) NOT BETWEEN 2 AND 2000 OR jsonb_typeof(provider_data)<>'object'
  OR jsonb_typeof(location_data)<>'object' OR jsonb_typeof(evidence)<>'array' OR jsonb_array_length(evidence)=0
  OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160
 THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_COMMAND_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,asset,trim(work_description),provider_data::TEXT,location_data::TEXT,evidence::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-condition:'||idem,0));
 SELECT * INTO prior FROM group_shared_asset_condition_events WHERE organization_id=o AND idempotency_key=idem;
 IF prior.id IS NOT NULL THEN
  IF prior.event_type<>'MAINTENANCE_STARTED' OR prior.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN prior.id;
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(asset::TEXT,0));
 SELECT * INTO current_asset FROM group_shared_assets WHERE id=asset AND organization_id=o AND group_id=g FOR UPDATE;
 IF current_asset.id IS NULL OR current_asset.lifecycle_state<>'active' THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_ASSET_INVALID'; END IF;
 IF current_asset.availability_state NOT IN('available','unavailable') OR EXISTS(
  SELECT 1 FROM group_shared_asset_reservations r WHERE r.asset_id=asset AND r.state IN('confirmed','checked_out') AND r.ends_at>at_time
 ) THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_ASSET_COMMITTED'; END IF;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_assets SET availability_state='maintenance',location=location_data,updated_at=at_time WHERE id=asset;
 INSERT INTO group_shared_asset_condition_events(organization_id,group_id,asset_id,actor_id,event_type,condition_before,condition_after,availability_before,availability_after,location_snapshot,details,evidence_refs,idempotency_key,request_hash,correlation_id,occurred_at)
 VALUES(o,g,asset,a,'MAINTENANCE_STARTED',current_asset.condition_state,current_asset.condition_state,current_asset.availability_state,'maintenance',location_data,
  jsonb_build_object('work_description',trim(work_description),'provider',provider_data),evidence,idem,h,corr,at_time) RETURNING id INTO event_id;
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN event_id;
END $$;

CREATE OR REPLACE FUNCTION complete_group_shared_asset_maintenance(
 o UUID,g UUID,a UUID,asset UUID,maintenance_event UUID,condition_name TEXT,completion_summary TEXT,
 location_data JSONB,next_due TIMESTAMPTZ,evidence JSONB,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE current_asset group_shared_assets; start_event group_shared_asset_condition_events; prior group_shared_asset_condition_events; event_id UUID; h TEXT; next_availability TEXT;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 IF condition_name NOT IN('new','good','fair','poor','damaged') OR char_length(trim(COALESCE(completion_summary,''))) NOT BETWEEN 2 AND 2000
  OR jsonb_typeof(location_data)<>'object' OR jsonb_typeof(evidence)<>'array' OR jsonb_array_length(evidence)=0
  OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160 OR (next_due IS NOT NULL AND next_due<=at_time)
 THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_COMMAND_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,asset,maintenance_event,condition_name,trim(completion_summary),location_data::TEXT,next_due,evidence::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-condition:'||idem,0));
 SELECT * INTO prior FROM group_shared_asset_condition_events WHERE organization_id=o AND idempotency_key=idem;
 IF prior.id IS NOT NULL THEN
  IF prior.event_type<>'MAINTENANCE_COMPLETED' OR prior.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN prior.id;
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(asset::TEXT,0));
 SELECT * INTO current_asset FROM group_shared_assets WHERE id=asset AND organization_id=o AND group_id=g FOR UPDATE;
 SELECT * INTO start_event FROM group_shared_asset_condition_events WHERE id=maintenance_event AND organization_id=o AND group_id=g AND asset_id=asset AND event_type='MAINTENANCE_STARTED';
 IF current_asset.id IS NULL OR current_asset.lifecycle_state<>'active' OR start_event.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_MAINTENANCE_INVALID'; END IF;
 IF current_asset.availability_state<>'maintenance' OR EXISTS(SELECT 1 FROM group_shared_asset_condition_events WHERE related_event_id=maintenance_event AND event_type='MAINTENANCE_COMPLETED')
 THEN RAISE EXCEPTION 'GROUP_ASSET_CONDITION_STATE_INVALID'; END IF;
 next_availability:=CASE WHEN condition_name='damaged' THEN 'unavailable' ELSE 'available' END;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_assets SET condition_state=condition_name,availability_state=next_availability,location=location_data,
  maintenance_schedule=maintenance_schedule||jsonb_strip_nulls(jsonb_build_object('last_completed_at',at_time,'next_due_at',next_due)),updated_at=at_time WHERE id=asset;
 INSERT INTO group_shared_asset_condition_events(organization_id,group_id,asset_id,actor_id,event_type,related_event_id,condition_before,condition_after,availability_before,availability_after,location_snapshot,details,evidence_refs,idempotency_key,request_hash,correlation_id,occurred_at)
 VALUES(o,g,asset,a,'MAINTENANCE_COMPLETED',maintenance_event,current_asset.condition_state,condition_name,current_asset.availability_state,next_availability,location_data,
  jsonb_build_object('completion_summary',trim(completion_summary),'next_due_at',next_due),evidence,idem,h,corr,at_time) RETURNING id INTO event_id;
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN event_id;
END $$;

REVOKE ALL ON FUNCTION
 report_group_shared_asset_damage(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ),
 start_group_shared_asset_maintenance(UUID,UUID,UUID,UUID,TEXT,JSONB,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ),
 complete_group_shared_asset_maintenance(UUID,UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,TIMESTAMPTZ,JSONB,TEXT,UUID,TIMESTAMPTZ)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
 report_group_shared_asset_damage(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ),
 start_group_shared_asset_maintenance(UUID,UUID,UUID,UUID,TEXT,JSONB,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ),
 complete_group_shared_asset_maintenance(UUID,UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,TIMESTAMPTZ,JSONB,TEXT,UUID,TIMESTAMPTZ)
 TO service_role;
