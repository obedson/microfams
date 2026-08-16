-- GT-10F auditable shared-asset loss reporting for uncommitted assets.
SET search_path=public,extensions;

CREATE TABLE IF NOT EXISTS group_shared_asset_loss_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id),
 asset_id UUID NOT NULL REFERENCES group_shared_assets(id),
 actor_id UUID NOT NULL REFERENCES users(id),
 lifecycle_before TEXT NOT NULL CHECK(lifecycle_before='active'),
 lifecycle_after TEXT NOT NULL CHECK(lifecycle_after='lost'),
 availability_before TEXT NOT NULL CHECK(availability_before IN('available','reserved','checked_out','maintenance','unavailable')),
 availability_after TEXT NOT NULL CHECK(availability_after='unavailable'),
 condition_snapshot TEXT NOT NULL CHECK(condition_snapshot IN('new','good','fair','poor','damaged')),
 custodian_member_id UUID NOT NULL REFERENCES group_members(id),
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
CREATE INDEX IF NOT EXISTS idx_group_asset_loss_events_asset ON group_shared_asset_loss_events(organization_id,group_id,asset_id,occurred_at);

DROP TRIGGER IF EXISTS protect_group_shared_asset_evidence ON group_shared_asset_loss_events;
CREATE TRIGGER protect_group_shared_asset_evidence BEFORE INSERT OR UPDATE OR DELETE ON group_shared_asset_loss_events FOR EACH ROW EXECUTE FUNCTION protect_group_shared_asset_evidence();

ALTER TABLE group_shared_asset_loss_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON group_shared_asset_loss_events FOR SELECT USING(has_active_organization_membership(organization_id));
REVOKE ALL ON group_shared_asset_loss_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_shared_asset_loss_events TO service_role;

CREATE OR REPLACE FUNCTION report_group_shared_asset_loss(
 o UUID,g UUID,a UUID,asset UUID,loss_type_name TEXT,description_text TEXT,location_data JSONB,evidence JSONB,
 idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE current_asset group_shared_assets; prior group_shared_asset_loss_events; event_id UUID; h TEXT;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 IF loss_type_name NOT IN('theft','misplaced','destroyed','unknown','other')
  OR char_length(trim(COALESCE(description_text,''))) NOT BETWEEN 2 AND 2000
  OR jsonb_typeof(location_data)<>'object' OR jsonb_typeof(evidence)<>'array' OR jsonb_array_length(evidence)=0
  OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160
 THEN RAISE EXCEPTION 'GROUP_ASSET_LOSS_COMMAND_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,asset,loss_type_name,trim(description_text),location_data::TEXT,evidence::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-loss:'||idem,0));
 SELECT * INTO prior FROM group_shared_asset_loss_events WHERE organization_id=o AND idempotency_key=idem;
 IF prior.id IS NOT NULL THEN
  IF prior.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_LOSS_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN prior.id;
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(asset::TEXT,0));
 SELECT * INTO current_asset FROM group_shared_assets WHERE id=asset AND organization_id=o AND group_id=g FOR UPDATE;
 IF current_asset.id IS NULL OR current_asset.lifecycle_state<>'active' THEN RAISE EXCEPTION 'GROUP_ASSET_LOSS_ASSET_INVALID'; END IF;
 IF current_asset.availability_state NOT IN('available','unavailable') OR EXISTS(
  SELECT 1 FROM group_shared_asset_reservations r
  WHERE r.asset_id=asset AND r.state IN('confirmed','checked_out') AND r.ends_at>at_time
 ) THEN RAISE EXCEPTION 'GROUP_ASSET_LOSS_ASSET_COMMITTED'; END IF;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_assets SET lifecycle_state='lost',availability_state='unavailable',location=location_data,updated_at=at_time WHERE id=asset;
 INSERT INTO group_shared_asset_loss_events(
  organization_id,group_id,asset_id,actor_id,lifecycle_before,lifecycle_after,availability_before,availability_after,
  condition_snapshot,custodian_member_id,location_snapshot,details,evidence_refs,idempotency_key,request_hash,correlation_id,occurred_at
 ) VALUES(
  o,g,asset,a,current_asset.lifecycle_state,'lost',current_asset.availability_state,'unavailable',current_asset.condition_state,
  current_asset.custodian_member_id,location_data,jsonb_build_object('loss_type',loss_type_name,'description',trim(description_text)),
  evidence,idem,h,corr,at_time
 ) RETURNING id INTO event_id;
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN event_id;
END $$;

REVOKE ALL ON FUNCTION report_group_shared_asset_loss(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION report_group_shared_asset_loss(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) TO service_role;
