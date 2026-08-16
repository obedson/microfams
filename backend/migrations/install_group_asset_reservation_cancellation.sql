-- GT-10G auditable cancellation of requested and confirmed shared-asset reservations.
SET search_path=public,extensions;

ALTER TABLE group_shared_asset_reservation_events DROP CONSTRAINT IF EXISTS group_shared_asset_reservation_events_event_type_check;
ALTER TABLE group_shared_asset_reservation_events ADD CONSTRAINT group_shared_asset_reservation_events_event_type_check
 CHECK(event_type IN('RESERVATION_REQUESTED','RESERVATION_CONFIRMED','ASSET_CHECKED_OUT','ASSET_CHECKED_IN','RESERVATION_CANCELLED'));

CREATE OR REPLACE FUNCTION cancel_group_shared_asset_reservation(
 o UUID,g UUID,a UUID,reservation UUID,reason_text TEXT,evidence JSONB,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_reservations; asset_row group_shared_assets; prior group_shared_asset_reservation_events; event_id UUID; h TEXT; manager_allowed BOOLEAN; requester_allowed BOOLEAN; next_availability TEXT;
BEGIN
 manager_allowed:=group_shared_asset_actor_permitted(o,a);
 SELECT EXISTS(
  SELECT 1 FROM group_shared_asset_reservations x JOIN group_members gm ON gm.id=x.requester_member_id
  WHERE x.id=reservation AND x.organization_id=o AND x.group_id=g AND gm.organization_id=o AND gm.group_id=g
   AND gm.user_id=a AND gm.status='active' AND gm.is_active=TRUE
   AND EXISTS(SELECT 1 FROM organization_memberships om WHERE om.organization_id=o AND om.user_id=a AND om.status='active')
 ) INTO requester_allowed;
 IF NOT manager_allowed AND NOT requester_allowed THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_CANCEL_PERMISSION_DENIED'; END IF;
 IF char_length(trim(COALESCE(reason_text,''))) NOT BETWEEN 2 AND 1000 OR jsonb_typeof(evidence)<>'object'
  OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160
 THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_CANCEL_COMMAND_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,reservation,trim(reason_text),evidence::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-reservation-cancel:'||idem,0));
 SELECT * INTO prior FROM group_shared_asset_reservation_events WHERE organization_id=o AND idempotency_key=idem;
 IF prior.id IS NOT NULL THEN
  IF prior.event_type<>'RESERVATION_CANCELLED' OR prior.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_CANCEL_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN prior.reservation_id;
 END IF;
 SELECT * INTO r FROM group_shared_asset_reservations WHERE id=reservation AND organization_id=o AND group_id=g FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_NOT_FOUND'; END IF;
 IF r.state NOT IN('requested','confirmed') THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_CANCEL_STATE_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(r.asset_id::TEXT,0));
 SELECT * INTO asset_row FROM group_shared_assets WHERE id=r.asset_id AND organization_id=o AND group_id=g FOR UPDATE;
 IF asset_row.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_ASSET_INVALID'; END IF;
 next_availability:=asset_row.availability_state;
 IF r.state='confirmed' AND asset_row.availability_state='reserved' AND NOT EXISTS(
  SELECT 1 FROM group_shared_asset_reservations x WHERE x.asset_id=r.asset_id AND x.id<>r.id AND x.state IN('confirmed','checked_out')
 ) THEN next_availability:='available'; END IF;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_asset_reservations SET state='cancelled',updated_at=at_time WHERE id=r.id;
 UPDATE group_shared_assets SET availability_state=next_availability,updated_at=at_time WHERE id=asset_row.id AND availability_state='reserved';
 INSERT INTO group_shared_asset_reservation_events(organization_id,group_id,asset_id,reservation_id,actor_id,event_type,idempotency_key,request_hash,correlation_id,evidence,occurred_at)
 VALUES(o,g,r.asset_id,r.id,a,'RESERVATION_CANCELLED',idem,h,corr,jsonb_build_object('prior_state',r.state,'reason',trim(reason_text),'evidence',evidence),at_time)
 RETURNING id INTO event_id;
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN r.id;
END $$;

REVOKE ALL ON FUNCTION cancel_group_shared_asset_reservation(UUID,UUID,UUID,UUID,TEXT,JSONB,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION cancel_group_shared_asset_reservation(UUID,UUID,UUID,UUID,TEXT,JSONB,TEXT,UUID,TIMESTAMPTZ) TO service_role;
