-- GT-10H atomic checked-out custody-loss resolution.
SET search_path=public,extensions;

ALTER TABLE group_shared_asset_reservations DROP CONSTRAINT IF EXISTS group_shared_asset_reservations_state_check;
ALTER TABLE group_shared_asset_reservations ADD CONSTRAINT group_shared_asset_reservations_state_check
 CHECK(state IN('requested','confirmed','checked_out','completed','cancelled','lost'));
ALTER TABLE group_shared_asset_reservations ADD COLUMN IF NOT EXISTS loss_event_id UUID REFERENCES group_shared_asset_loss_events(id);
ALTER TABLE group_shared_asset_reservations ADD COLUMN IF NOT EXISTS lost_by UUID REFERENCES users(id);
ALTER TABLE group_shared_asset_reservations ADD COLUMN IF NOT EXISTS lost_at TIMESTAMPTZ;
ALTER TABLE group_shared_asset_reservations DROP CONSTRAINT IF EXISTS group_shared_asset_reservations_loss_consistency;
ALTER TABLE group_shared_asset_reservations ADD CONSTRAINT group_shared_asset_reservations_loss_consistency CHECK(
 (state='lost' AND loss_event_id IS NOT NULL AND lost_by IS NOT NULL AND lost_at IS NOT NULL)
 OR (state<>'lost' AND loss_event_id IS NULL AND lost_by IS NULL AND lost_at IS NULL)
);

ALTER TABLE group_shared_asset_reservation_events DROP CONSTRAINT IF EXISTS group_shared_asset_reservation_events_event_type_check;
ALTER TABLE group_shared_asset_reservation_events ADD CONSTRAINT group_shared_asset_reservation_events_event_type_check
 CHECK(event_type IN('RESERVATION_REQUESTED','RESERVATION_CONFIRMED','ASSET_CHECKED_OUT','ASSET_CHECKED_IN','RESERVATION_CANCELLED','ASSET_LOSS_REPORTED'));

CREATE OR REPLACE FUNCTION report_checked_out_group_shared_asset_loss(
 o UUID,g UUID,a UUID,reservation UUID,loss_type_name TEXT,description_text TEXT,location_data JSONB,evidence JSONB,
 idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_reservations; current_asset group_shared_assets; prior group_shared_asset_reservation_events; loss_id UUID; h TEXT;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 IF loss_type_name NOT IN('theft','misplaced','destroyed','unknown','other')
  OR char_length(trim(COALESCE(description_text,''))) NOT BETWEEN 2 AND 2000
  OR jsonb_typeof(location_data)<>'object' OR jsonb_typeof(evidence)<>'array' OR jsonb_array_length(evidence)=0
  OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160
 THEN RAISE EXCEPTION 'GROUP_ASSET_CUSTODY_LOSS_COMMAND_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,reservation,loss_type_name,trim(description_text),location_data::TEXT,evidence::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-custody-loss:'||idem,0));
 SELECT * INTO prior FROM group_shared_asset_reservation_events WHERE organization_id=o AND idempotency_key=idem;
 IF prior.id IS NOT NULL THEN
  IF prior.event_type<>'ASSET_LOSS_REPORTED' OR prior.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_CUSTODY_LOSS_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN (prior.evidence->>'loss_event_id')::UUID;
 END IF;
 SELECT * INTO r FROM group_shared_asset_reservations WHERE id=reservation AND organization_id=o AND group_id=g FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_NOT_FOUND'; END IF;
 IF r.state<>'checked_out' OR r.checked_out_at IS NULL OR at_time<r.checked_out_at THEN RAISE EXCEPTION 'GROUP_ASSET_CUSTODY_LOSS_STATE_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(r.asset_id::TEXT,0));
 SELECT * INTO current_asset FROM group_shared_assets WHERE id=r.asset_id AND organization_id=o AND group_id=g FOR UPDATE;
 IF current_asset.id IS NULL OR current_asset.lifecycle_state<>'active' OR current_asset.availability_state<>'checked_out' THEN RAISE EXCEPTION 'GROUP_ASSET_CUSTODY_LOSS_ASSET_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM group_shared_asset_reservations x WHERE x.asset_id=r.asset_id AND x.id<>r.id AND x.state IN('requested','confirmed'))
 THEN RAISE EXCEPTION 'GROUP_ASSET_CUSTODY_LOSS_PENDING_RESERVATIONS'; END IF;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 INSERT INTO group_shared_asset_loss_events(
  organization_id,group_id,asset_id,actor_id,lifecycle_before,lifecycle_after,availability_before,availability_after,
  condition_snapshot,custodian_member_id,location_snapshot,details,evidence_refs,idempotency_key,request_hash,correlation_id,occurred_at
 ) VALUES(
  o,g,r.asset_id,a,current_asset.lifecycle_state,'lost',current_asset.availability_state,'unavailable',current_asset.condition_state,
  current_asset.custodian_member_id,location_data,jsonb_build_object('loss_type',loss_type_name,'description',trim(description_text),
   'reservation_id',r.id,'recipient_member_id',r.checkout_recipient_member_id),evidence,idem,h,corr,at_time
 ) RETURNING id INTO loss_id;
 UPDATE group_shared_asset_reservations SET state='lost',loss_event_id=loss_id,lost_by=a,lost_at=at_time,updated_at=at_time WHERE id=r.id;
 UPDATE group_shared_assets SET lifecycle_state='lost',availability_state='unavailable',location=location_data,updated_at=at_time WHERE id=r.asset_id;
 INSERT INTO group_shared_asset_reservation_events(organization_id,group_id,asset_id,reservation_id,actor_id,event_type,idempotency_key,request_hash,correlation_id,evidence,occurred_at)
 VALUES(o,g,r.asset_id,r.id,a,'ASSET_LOSS_REPORTED',idem,h,corr,jsonb_build_object('loss_event_id',loss_id,'recipient_member_id',r.checkout_recipient_member_id,
  'loss_type',loss_type_name,'description',trim(description_text),'location',location_data,'evidence_refs',evidence),at_time);
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN loss_id;
END $$;

REVOKE ALL ON FUNCTION report_checked_out_group_shared_asset_loss(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION report_checked_out_group_shared_asset_loss(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) TO service_role;
