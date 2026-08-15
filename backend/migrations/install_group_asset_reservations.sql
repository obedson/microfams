-- GT-10D non-overlapping shared-asset reservations and auditable custody hand-off.
SET search_path=public,extensions;

CREATE TABLE IF NOT EXISTS group_shared_asset_reservations (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id),
 asset_id UUID NOT NULL REFERENCES group_shared_assets(id),
 requester_member_id UUID NOT NULL REFERENCES group_members(id),
 purpose TEXT NOT NULL CHECK(char_length(trim(purpose)) BETWEEN 2 AND 1000),
 starts_at TIMESTAMPTZ NOT NULL, ends_at TIMESTAMPTZ NOT NULL,
 state TEXT NOT NULL DEFAULT 'requested' CHECK(state IN('requested','confirmed','checked_out','completed','cancelled')),
 request_evidence JSONB NOT NULL CHECK(jsonb_typeof(request_evidence)='array' AND jsonb_array_length(request_evidence)>0),
 created_by UUID NOT NULL REFERENCES users(id),
 idempotency_key TEXT NOT NULL CHECK(char_length(trim(idempotency_key)) BETWEEN 8 AND 160),
 request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL,
 confirmed_by UUID REFERENCES users(id), confirmed_at TIMESTAMPTZ,
 checkout_recipient_member_id UUID REFERENCES group_members(id),
 checkout_condition TEXT CHECK(checkout_condition IN('new','good','fair','poor','damaged')),
 checkout_location JSONB CHECK(checkout_location IS NULL OR jsonb_typeof(checkout_location)='object'),
 checkout_evidence JSONB CHECK(checkout_evidence IS NULL OR (jsonb_typeof(checkout_evidence)='array' AND jsonb_array_length(checkout_evidence)>0)),
 checked_out_by UUID REFERENCES users(id), checked_out_at TIMESTAMPTZ,
 return_condition TEXT CHECK(return_condition IN('new','good','fair','poor','damaged')),
 return_location JSONB CHECK(return_location IS NULL OR jsonb_typeof(return_location)='object'),
 return_evidence JSONB CHECK(return_evidence IS NULL OR (jsonb_typeof(return_evidence)='array' AND jsonb_array_length(return_evidence)>0)),
 checked_in_by UUID REFERENCES users(id), checked_in_at TIMESTAMPTZ,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 CHECK(ends_at>starts_at), UNIQUE(organization_id,idempotency_key), UNIQUE(organization_id,correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_group_asset_reservations_asset ON group_shared_asset_reservations(organization_id,group_id,asset_id,starts_at,ends_at) WHERE state IN('confirmed','checked_out');

CREATE TABLE IF NOT EXISTS group_shared_asset_reservation_events (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), organization_id UUID NOT NULL REFERENCES organizations(id),
 group_id UUID NOT NULL REFERENCES groups(id), asset_id UUID NOT NULL REFERENCES group_shared_assets(id),
 reservation_id UUID NOT NULL REFERENCES group_shared_asset_reservations(id), actor_id UUID NOT NULL REFERENCES users(id),
 event_type TEXT NOT NULL CHECK(event_type IN('RESERVATION_REQUESTED','RESERVATION_CONFIRMED','ASSET_CHECKED_OUT','ASSET_CHECKED_IN')),
 idempotency_key TEXT NOT NULL CHECK(char_length(trim(idempotency_key)) BETWEEN 8 AND 160),
 request_hash VARCHAR(64) NOT NULL CHECK(request_hash~'^[a-f0-9]{64}$'), correlation_id UUID NOT NULL,
 evidence JSONB NOT NULL CHECK(jsonb_typeof(evidence)='object'), occurred_at TIMESTAMPTZ NOT NULL,
 UNIQUE(organization_id,idempotency_key), UNIQUE(organization_id,correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_group_asset_reservation_events ON group_shared_asset_reservation_events(organization_id,group_id,asset_id,reservation_id,occurred_at);

DROP TRIGGER IF EXISTS protect_group_shared_asset_evidence ON group_shared_asset_reservations;
CREATE TRIGGER protect_group_shared_asset_evidence BEFORE INSERT OR UPDATE OR DELETE ON group_shared_asset_reservations FOR EACH ROW EXECUTE FUNCTION protect_group_shared_asset_evidence();
DROP TRIGGER IF EXISTS protect_group_shared_asset_evidence ON group_shared_asset_reservation_events;
CREATE TRIGGER protect_group_shared_asset_evidence BEFORE INSERT OR UPDATE OR DELETE ON group_shared_asset_reservation_events FOR EACH ROW EXECUTE FUNCTION protect_group_shared_asset_evidence();

CREATE OR REPLACE FUNCTION group_shared_asset_member_valid(o UUID,g UUID,m UUID) RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM group_members gm WHERE gm.id=m AND gm.organization_id=o AND gm.group_id=g AND gm.status='active' AND gm.is_active=TRUE);
$$;

ALTER TABLE group_shared_asset_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_shared_asset_reservation_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON group_shared_asset_reservations FOR SELECT USING(has_active_organization_membership(organization_id));
CREATE POLICY tenant_read ON group_shared_asset_reservation_events FOR SELECT USING(has_active_organization_membership(organization_id));
REVOKE ALL ON group_shared_asset_reservations,group_shared_asset_reservation_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_shared_asset_reservations,group_shared_asset_reservation_events TO service_role;

CREATE OR REPLACE FUNCTION request_group_shared_asset_reservation(o UUID,g UUID,a UUID,asset UUID,requester UUID,purpose_text TEXT,starts TIMESTAMPTZ,ends TIMESTAMPTZ,evidence JSONB,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE reservation_id UUID; existing group_shared_asset_reservations; h TEXT;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM organization_memberships WHERE organization_id=o AND user_id=a AND status='active')
  OR NOT group_shared_asset_member_valid(o,g,requester) OR NOT EXISTS(SELECT 1 FROM group_members WHERE id=requester AND user_id=a)
 THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_MEMBER_INVALID'; END IF;
 IF ends<=starts OR char_length(trim(COALESCE(purpose_text,''))) NOT BETWEEN 2 AND 1000 OR jsonb_typeof(evidence)<>'array'
  OR jsonb_array_length(evidence)=0 OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160
 THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_COMMAND_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,asset,requester,trim(purpose_text),starts,ends,evidence::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-reservation:'||idem,0));
 SELECT * INTO existing FROM group_shared_asset_reservations WHERE organization_id=o AND idempotency_key=idem;
 IF existing.id IS NOT NULL THEN
  IF existing.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN existing.id;
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(asset::TEXT,0));
 IF NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=asset AND organization_id=o AND group_id=g AND lifecycle_state='active')
 THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_ASSET_INVALID'; END IF;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 INSERT INTO group_shared_asset_reservations(organization_id,group_id,asset_id,requester_member_id,purpose,starts_at,ends_at,request_evidence,created_by,idempotency_key,request_hash,correlation_id,created_at,updated_at)
 VALUES(o,g,asset,requester,trim(purpose_text),starts,ends,evidence,a,idem,h,corr,at_time,at_time) RETURNING id INTO reservation_id;
 INSERT INTO group_shared_asset_reservation_events(organization_id,group_id,asset_id,reservation_id,actor_id,event_type,idempotency_key,request_hash,correlation_id,evidence,occurred_at)
 VALUES(o,g,asset,reservation_id,a,'RESERVATION_REQUESTED',idem,h,corr,jsonb_build_object('requester_member_id',requester,'purpose',trim(purpose_text),'starts_at',starts,'ends_at',ends,'evidence_refs',evidence),at_time);
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN reservation_id;
END $$;

CREATE OR REPLACE FUNCTION confirm_group_shared_asset_reservation(o UUID,g UUID,a UUID,reservation UUID,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_reservations; prior group_shared_asset_reservation_events; h TEXT;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 IF char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160 THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_COMMAND_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,reservation),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-reservation-event:'||idem,0));
 SELECT * INTO prior FROM group_shared_asset_reservation_events WHERE organization_id=o AND idempotency_key=idem;
 IF prior.id IS NOT NULL THEN
  IF prior.event_type<>'RESERVATION_CONFIRMED' OR prior.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN prior.reservation_id;
 END IF;
 SELECT * INTO r FROM group_shared_asset_reservations WHERE id=reservation AND organization_id=o AND group_id=g FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_NOT_FOUND'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(r.asset_id::TEXT,0));
 IF r.state<>'requested' THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_STATE_INVALID'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=r.asset_id AND lifecycle_state='active' AND availability_state IN('available','reserved'))
 THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_ASSET_UNAVAILABLE'; END IF;
 IF EXISTS(SELECT 1 FROM group_shared_asset_reservations x WHERE x.asset_id=r.asset_id AND x.id<>r.id AND x.state IN('confirmed','checked_out')
  AND tstzrange(x.starts_at,x.ends_at,'[)')&&tstzrange(r.starts_at,r.ends_at,'[)'))
 THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_OVERLAP' USING ERRCODE='23P01'; END IF;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_asset_reservations SET state='confirmed',confirmed_by=a,confirmed_at=at_time,updated_at=at_time WHERE id=r.id;
 UPDATE group_shared_assets SET availability_state='reserved',updated_at=at_time WHERE id=r.asset_id AND availability_state='available';
 INSERT INTO group_shared_asset_reservation_events(organization_id,group_id,asset_id,reservation_id,actor_id,event_type,idempotency_key,request_hash,correlation_id,evidence,occurred_at)
 VALUES(o,g,r.asset_id,r.id,a,'RESERVATION_CONFIRMED',idem,h,corr,jsonb_build_object('starts_at',r.starts_at,'ends_at',r.ends_at),at_time);
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN r.id;
END $$;

CREATE OR REPLACE FUNCTION check_out_group_shared_asset(o UUID,g UUID,a UUID,reservation UUID,recipient UUID,condition_name TEXT,location_data JSONB,evidence JSONB,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_reservations; prior group_shared_asset_reservation_events; h TEXT;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 IF NOT group_shared_asset_member_valid(o,g,recipient) THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_MEMBER_INVALID'; END IF;
 IF condition_name NOT IN('new','good','fair','poor','damaged') OR jsonb_typeof(location_data)<>'object' OR jsonb_typeof(evidence)<>'array'
  OR jsonb_array_length(evidence)=0 OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160
 THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_COMMAND_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,reservation,recipient,condition_name,location_data::TEXT,evidence::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-reservation-event:'||idem,0));
 SELECT * INTO prior FROM group_shared_asset_reservation_events WHERE organization_id=o AND idempotency_key=idem;
 IF prior.id IS NOT NULL THEN
  IF prior.event_type<>'ASSET_CHECKED_OUT' OR prior.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN prior.reservation_id;
 END IF;
 SELECT * INTO r FROM group_shared_asset_reservations WHERE id=reservation AND organization_id=o AND group_id=g FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_NOT_FOUND'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(r.asset_id::TEXT,0));
 IF r.state<>'confirmed' THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_STATE_INVALID'; END IF;
 IF at_time<r.starts_at OR at_time>=r.ends_at THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_CHECKOUT_WINDOW_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM group_shared_asset_reservations WHERE asset_id=r.asset_id AND id<>r.id AND state='checked_out')
  OR NOT EXISTS(SELECT 1 FROM group_shared_assets WHERE id=r.asset_id AND lifecycle_state='active' AND availability_state='reserved')
 THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_ASSET_UNAVAILABLE'; END IF;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_asset_reservations SET state='checked_out',checkout_recipient_member_id=recipient,checkout_condition=condition_name,
  checkout_location=location_data,checkout_evidence=evidence,checked_out_by=a,checked_out_at=at_time,updated_at=at_time WHERE id=r.id;
 UPDATE group_shared_assets SET availability_state='checked_out',updated_at=at_time WHERE id=r.asset_id;
 INSERT INTO group_shared_asset_reservation_events(organization_id,group_id,asset_id,reservation_id,actor_id,event_type,idempotency_key,request_hash,correlation_id,evidence,occurred_at)
 VALUES(o,g,r.asset_id,r.id,a,'ASSET_CHECKED_OUT',idem,h,corr,jsonb_build_object('recipient_member_id',recipient,'condition',condition_name,'location',location_data,'evidence_refs',evidence),at_time);
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN r.id;
END $$;

CREATE OR REPLACE FUNCTION check_in_group_shared_asset(o UUID,g UUID,a UUID,reservation UUID,condition_name TEXT,location_data JSONB,evidence JSONB,idem TEXT,corr UUID,at_time TIMESTAMPTZ DEFAULT NOW()) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE r group_shared_asset_reservations; prior group_shared_asset_reservation_events; h TEXT; next_availability TEXT;
BEGIN
 IF NOT group_shared_asset_actor_permitted(o,a) THEN RAISE EXCEPTION 'GROUP_SHARED_ASSET_PERMISSION_DENIED'; END IF;
 IF condition_name NOT IN('new','good','fair','poor','damaged') OR jsonb_typeof(location_data)<>'object' OR jsonb_typeof(evidence)<>'array'
  OR jsonb_array_length(evidence)=0 OR char_length(trim(COALESCE(idem,''))) NOT BETWEEN 8 AND 160
 THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_COMMAND_INVALID'; END IF;
 h:=encode(digest(convert_to(concat_ws('|',o,g,a,reservation,condition_name,location_data::TEXT,evidence::TEXT),'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(o::TEXT||':group-asset-reservation-event:'||idem,0));
 SELECT * INTO prior FROM group_shared_asset_reservation_events WHERE organization_id=o AND idempotency_key=idem;
 IF prior.id IS NOT NULL THEN
  IF prior.event_type<>'ASSET_CHECKED_IN' OR prior.request_hash<>h THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN prior.reservation_id;
 END IF;
 SELECT * INTO r FROM group_shared_asset_reservations WHERE id=reservation AND organization_id=o AND group_id=g FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_NOT_FOUND'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(r.asset_id::TEXT,0));
 IF r.state<>'checked_out' OR at_time<r.checked_out_at THEN RAISE EXCEPTION 'GROUP_ASSET_RESERVATION_STATE_INVALID'; END IF;
 next_availability:=CASE WHEN EXISTS(SELECT 1 FROM group_shared_asset_reservations x WHERE x.asset_id=r.asset_id AND x.id<>r.id AND x.state='confirmed' AND x.ends_at>at_time) THEN 'reserved' ELSE 'available' END;
 PERFORM set_config('microfams.group_shared_asset_engine','on',TRUE);
 UPDATE group_shared_asset_reservations SET state='completed',return_condition=condition_name,return_location=location_data,
  return_evidence=evidence,checked_in_by=a,checked_in_at=at_time,updated_at=at_time WHERE id=r.id;
 UPDATE group_shared_assets SET condition_state=condition_name,location=location_data,availability_state=next_availability,updated_at=at_time WHERE id=r.asset_id;
 INSERT INTO group_shared_asset_reservation_events(organization_id,group_id,asset_id,reservation_id,actor_id,event_type,idempotency_key,request_hash,correlation_id,evidence,occurred_at)
 VALUES(o,g,r.asset_id,r.id,a,'ASSET_CHECKED_IN',idem,h,corr,jsonb_build_object('condition',condition_name,'location',location_data,'evidence_refs',evidence),at_time);
 PERFORM set_config('microfams.group_shared_asset_engine','',TRUE);
 RETURN r.id;
END $$;

REVOKE ALL ON FUNCTION group_shared_asset_member_valid(UUID,UUID,UUID),
 request_group_shared_asset_reservation(UUID,UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,JSONB,TEXT,UUID,TIMESTAMPTZ),
 confirm_group_shared_asset_reservation(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ),
 check_out_group_shared_asset(UUID,UUID,UUID,UUID,UUID,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ),
 check_in_group_shared_asset(UUID,UUID,UUID,UUID,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
 request_group_shared_asset_reservation(UUID,UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,JSONB,TEXT,UUID,TIMESTAMPTZ),
 confirm_group_shared_asset_reservation(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ),
 check_out_group_shared_asset(UUID,UUID,UUID,UUID,UUID,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ),
 check_in_group_shared_asset(UUID,UUID,UUID,UUID,TEXT,JSONB,JSONB,TEXT,UUID,TIMESTAMPTZ) TO service_role;
