-- GT-10I atomic reservation cancellation when an uncommitted asset is reported lost.
SET search_path=public,extensions;

CREATE OR REPLACE FUNCTION report_group_shared_asset_loss(
 o UUID,g UUID,a UUID,asset UUID,loss_type_name TEXT,description_text TEXT,location_data JSONB,evidence JSONB,
 idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE current_asset group_shared_assets; prior group_shared_asset_loss_events; event_id UUID; h TEXT;
 reservation_row group_shared_asset_reservations; cancellation_hash TEXT; cancelled_count INTEGER;
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
 IF current_asset.availability_state NOT IN('available','reserved','unavailable') OR EXISTS(
  SELECT 1 FROM group_shared_asset_reservations r WHERE r.asset_id=asset AND r.state='checked_out'
 ) THEN RAISE EXCEPTION 'GROUP_ASSET_LOSS_ASSET_COMMITTED'; END IF;
 SELECT count(*) INTO cancelled_count FROM group_shared_asset_reservations
 WHERE asset_id=asset AND organization_id=o AND group_id=g AND state IN('requested','confirmed');
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_assets SET lifecycle_state='lost',availability_state='unavailable',location=location_data,updated_at=at_time WHERE id=asset;
 INSERT INTO group_shared_asset_loss_events(
  organization_id,group_id,asset_id,actor_id,lifecycle_before,lifecycle_after,availability_before,availability_after,
  condition_snapshot,custodian_member_id,location_snapshot,details,evidence_refs,idempotency_key,request_hash,correlation_id,occurred_at
 ) VALUES(
  o,g,asset,a,current_asset.lifecycle_state,'lost',current_asset.availability_state,'unavailable',current_asset.condition_state,
  current_asset.custodian_member_id,location_data,jsonb_build_object('loss_type',loss_type_name,'description',trim(description_text),
   'cancelled_reservation_count',cancelled_count),evidence,idem,h,corr,at_time
 ) RETURNING id INTO event_id;
 FOR reservation_row IN
  SELECT * FROM group_shared_asset_reservations
  WHERE asset_id=asset AND organization_id=o AND group_id=g AND state IN('requested','confirmed')
  ORDER BY id FOR UPDATE
 LOOP
  cancellation_hash:=encode(digest(convert_to(concat_ws('|',o,g,a,event_id,reservation_row.id,reservation_row.state),'UTF8'),'sha256'),'hex');
  UPDATE group_shared_asset_reservations SET state='cancelled',updated_at=at_time WHERE id=reservation_row.id;
  INSERT INTO group_shared_asset_reservation_events(
   organization_id,group_id,asset_id,reservation_id,actor_id,event_type,idempotency_key,request_hash,correlation_id,evidence,occurred_at
  ) VALUES(
   o,g,asset,reservation_row.id,a,'RESERVATION_CANCELLED','lifecycle-loss:'||event_id::TEXT||':'||reservation_row.id::TEXT,
   cancellation_hash,gen_random_uuid(),jsonb_build_object('prior_state',reservation_row.state,
    'reason','Asset lifecycle changed to lost','cancellation_source','asset_lifecycle','loss_event_id',event_id),at_time
  );
 END LOOP;
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN event_id;
END $$;

REVOKE ALL ON FUNCTION report_group_shared_asset_loss(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION report_group_shared_asset_loss(UUID,UUID,UUID,UUID,TEXT,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) TO service_role;
