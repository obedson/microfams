-- GT-02B1: tenant-bound, hashed, single-use group membership invitations.
SET search_path = public, extensions;

ALTER TABLE group_members
  ADD COLUMN IF NOT EXISTS state_version INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS status_reason_code TEXT,
  ADD COLUMN IF NOT EXISTS invited_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS exiting_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS exited_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS expelled_at TIMESTAMPTZ;
ALTER TABLE group_members DROP CONSTRAINT IF EXISTS group_members_status_check;
ALTER TABLE group_members ADD CONSTRAINT group_members_status_check CHECK (
  status IN ('invited','applicant','pending_payment','active','suspended','exiting','exited','expelled')
);
ALTER TABLE group_members DROP CONSTRAINT IF EXISTS group_members_state_version_check;
ALTER TABLE group_members ADD CONSTRAINT group_members_state_version_check
  CHECK (state_version > 0);

CREATE TABLE IF NOT EXISTS group_membership_invitations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  constitution_id UUID NOT NULL REFERENCES group_constitutions(id) ON DELETE RESTRICT,
  intended_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  token_digest TEXT NOT NULL UNIQUE CHECK (token_digest ~ '^[0-9a-f]{64}$'),
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending','accepted','revoked','expired')),
  expires_at TIMESTAMPTZ NOT NULL,
  invited_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  accepted_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (expires_at > created_at),
  CHECK ((state = 'accepted') = (accepted_at IS NOT NULL)),
  CHECK ((state = 'revoked') = (revoked_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_group_pending_user_invitation
  ON group_membership_invitations(group_id, intended_user_id)
  WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS idx_group_invitation_tenant
  ON group_membership_invitations(organization_id, group_id, state, expires_at);

CREATE TABLE IF NOT EXISTS group_membership_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
  membership_id UUID REFERENCES group_members(id) ON DELETE RESTRICT,
  invitation_id UUID REFERENCES group_membership_invitations(id) ON DELETE RESTRICT,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL CHECK (event_type ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  from_state TEXT,
  to_state TEXT,
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  correlation_id UUID NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(evidence)='object'),
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, correlation_id)
);

CREATE OR REPLACE FUNCTION protect_group_membership_evidence() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF current_setting('microfams.group_membership_engine', TRUE)='on' THEN
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'GROUP_MEMBERSHIP_ENGINE_REQUIRED';
END $$;
DROP TRIGGER IF EXISTS protect_group_invitations ON group_membership_invitations;
CREATE TRIGGER protect_group_invitations BEFORE UPDATE OR DELETE
  ON group_membership_invitations FOR EACH ROW
  EXECUTE FUNCTION protect_group_membership_evidence();
DROP TRIGGER IF EXISTS protect_group_membership_events ON group_membership_events;
CREATE TRIGGER protect_group_membership_events BEFORE INSERT OR UPDATE OR DELETE
  ON group_membership_events FOR EACH ROW
  EXECUTE FUNCTION protect_group_membership_evidence();
CREATE OR REPLACE FUNCTION protect_group_membership_state() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF (NEW.status,NEW.state_version,NEW.status_reason_code,NEW.exiting_at,
      NEW.exited_at,NEW.expelled_at,NEW.is_active) IS DISTINCT FROM
     (OLD.status,OLD.state_version,OLD.status_reason_code,OLD.exiting_at,
      OLD.exited_at,OLD.expelled_at,OLD.is_active)
    AND current_setting('microfams.group_membership_engine',TRUE)<>'on'
  THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_ENGINE_REQUIRED'; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS protect_group_membership_state_trigger ON group_members;
CREATE TRIGGER protect_group_membership_state_trigger BEFORE UPDATE ON group_members
  FOR EACH ROW EXECUTE FUNCTION protect_group_membership_state();

CREATE OR REPLACE FUNCTION create_group_membership_invitation(
  p_organization_id UUID, p_group_id UUID, p_actor_id UUID,
  p_intended_user_id UUID, p_token_digest TEXT, p_expires_at TIMESTAMPTZ,
  p_correlation_id UUID, p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_group groups; v_id UUID; v_setting TEXT;
BEGIN
  IF p_token_digest !~ '^[0-9a-f]{64}$' OR p_expires_at<=p_occurred_at
    OR p_correlation_id IS NULL THEN RAISE EXCEPTION 'GROUP_INVITATION_COMMAND_INVALID'; END IF;
  SELECT invitation_id INTO v_id FROM group_membership_events
  WHERE organization_id=p_organization_id AND correlation_id=p_correlation_id;
  IF FOUND THEN RETURN jsonb_build_object('invitation_id',v_id,'created',FALSE); END IF;
  PERFORM assert_group_governance_actor(p_organization_id,p_group_id,p_actor_id);
  SELECT * INTO v_group FROM groups WHERE id=p_group_id
    AND organization_id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF v_group.lifecycle_state<>'active' THEN RAISE EXCEPTION 'GROUP_NOT_ACCEPTING_MEMBERS'; END IF;
  IF NOT EXISTS (SELECT 1 FROM organization_memberships WHERE
    organization_id=p_organization_id AND user_id=p_intended_user_id AND status='active')
  THEN RAISE EXCEPTION 'INVITEE_TENANT_MEMBERSHIP_REQUIRED'; END IF;
  IF EXISTS (SELECT 1 FROM group_members WHERE group_id=p_group_id
    AND user_id=p_intended_user_id)
  THEN RAISE EXCEPTION 'GROUP_MEMBERSHIP_ALREADY_EXISTS'; END IF;
  v_setting:=current_setting('microfams.group_membership_engine',TRUE);
  PERFORM set_config('microfams.group_membership_engine','on',TRUE);
  UPDATE group_membership_invitations SET state='expired'
  WHERE group_id=p_group_id AND intended_user_id=p_intended_user_id
    AND state='pending' AND expires_at<=p_occurred_at;
  INSERT INTO group_membership_invitations(
    organization_id,group_id,constitution_id,intended_user_id,token_digest,
    expires_at,invited_by,created_at
  ) VALUES (
    p_organization_id,p_group_id,v_group.current_constitution_id,p_intended_user_id,
    p_token_digest,p_expires_at,p_actor_id,p_occurred_at
  ) RETURNING id INTO v_id;
  INSERT INTO group_membership_events(
    organization_id,group_id,invitation_id,actor_id,event_type,from_state,to_state,
    reason_code,correlation_id,occurred_at
  ) VALUES (
    p_organization_id,p_group_id,v_id,p_actor_id,'INVITATION_CREATED',NULL,'pending',
    'MEMBERSHIP_INVITED',p_correlation_id,p_occurred_at
  );
  PERFORM set_config('microfams.group_membership_engine',COALESCE(v_setting,''),TRUE);
  RETURN jsonb_build_object('invitation_id',v_id,'created',TRUE);
END $$;

CREATE OR REPLACE FUNCTION accept_group_membership_invitation(
  p_organization_id UUID, p_group_id UUID, p_actor_id UUID, p_token_digest TEXT,
  p_correlation_id UUID, p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_invite group_membership_invitations; v_member UUID; v_setting TEXT;
BEGIN
  IF p_token_digest !~ '^[0-9a-f]{64}$' OR p_correlation_id IS NULL
  THEN RAISE EXCEPTION 'GROUP_INVITATION_COMMAND_INVALID'; END IF;
  SELECT membership_id INTO v_member FROM group_membership_events
  WHERE organization_id=p_organization_id AND correlation_id=p_correlation_id;
  IF FOUND THEN RETURN v_member; END IF;
  SELECT * INTO v_invite FROM group_membership_invitations
  WHERE organization_id=p_organization_id AND group_id=p_group_id
    AND token_digest=p_token_digest FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_INVITATION_NOT_FOUND'; END IF;
  IF v_invite.intended_user_id<>p_actor_id THEN RAISE EXCEPTION 'GROUP_INVITATION_NOT_FOUND'; END IF;
  IF v_invite.state<>'pending' OR v_invite.expires_at<=p_occurred_at
  THEN RAISE EXCEPTION 'GROUP_INVITATION_UNAVAILABLE'; END IF;
  IF NOT EXISTS (SELECT 1 FROM groups WHERE id=v_invite.group_id
    AND organization_id=p_organization_id AND lifecycle_state='active')
  THEN RAISE EXCEPTION 'GROUP_NOT_ACCEPTING_MEMBERS'; END IF;
  IF (SELECT count(*) FROM group_members WHERE group_id=v_invite.group_id
      AND status IN ('applicant','pending_payment','active','suspended','exiting')) >=
     (SELECT max_members FROM groups WHERE id=v_invite.group_id)
  THEN RAISE EXCEPTION 'GROUP_CAPACITY_REACHED'; END IF;
  v_setting:=current_setting('microfams.group_membership_engine',TRUE);
  PERFORM set_config('microfams.group_membership_engine','on',TRUE);
  INSERT INTO group_members(organization_id,group_id,user_id,status,is_active,invited_at)
  VALUES(p_organization_id,v_invite.group_id,p_actor_id,'applicant',FALSE,v_invite.created_at)
  RETURNING id INTO v_member;
  UPDATE group_membership_invitations SET state='accepted',accepted_at=p_occurred_at
  WHERE id=v_invite.id;
  INSERT INTO group_membership_events(
    organization_id,group_id,membership_id,invitation_id,actor_id,event_type,
    from_state,to_state,reason_code,correlation_id,occurred_at
  ) VALUES (
    p_organization_id,v_invite.group_id,v_member,v_invite.id,p_actor_id,
    'INVITATION_ACCEPTED','invited','applicant','INVITATION_ACCEPTED',
    p_correlation_id,p_occurred_at
  );
  PERFORM set_config('microfams.group_membership_engine',COALESCE(v_setting,''),TRUE);
  RETURN v_member;
END $$;

CREATE OR REPLACE FUNCTION revoke_group_membership_invitation(
  p_organization_id UUID,p_group_id UUID,p_actor_id UUID,p_invitation_id UUID,
  p_reason_code TEXT,p_correlation_id UUID,p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_invite group_membership_invitations; v_prior UUID; v_setting TEXT;
BEGIN
  IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' OR p_correlation_id IS NULL
  THEN RAISE EXCEPTION 'GROUP_INVITATION_COMMAND_INVALID'; END IF;
  SELECT invitation_id INTO v_prior FROM group_membership_events
  WHERE organization_id=p_organization_id AND correlation_id=p_correlation_id;
  IF FOUND THEN RETURN v_prior; END IF;
  PERFORM assert_group_governance_actor(p_organization_id,p_group_id,p_actor_id);
  SELECT * INTO v_invite FROM group_membership_invitations
  WHERE id=p_invitation_id AND organization_id=p_organization_id
    AND group_id=p_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_INVITATION_NOT_FOUND'; END IF;
  IF v_invite.state<>'pending' THEN RAISE EXCEPTION 'GROUP_INVITATION_UNAVAILABLE'; END IF;
  v_setting:=current_setting('microfams.group_membership_engine',TRUE);
  PERFORM set_config('microfams.group_membership_engine','on',TRUE);
  UPDATE group_membership_invitations SET state='revoked',revoked_at=p_occurred_at
  WHERE id=v_invite.id;
  INSERT INTO group_membership_events(
    organization_id,group_id,invitation_id,actor_id,event_type,from_state,to_state,
    reason_code,correlation_id,occurred_at
  ) VALUES(p_organization_id,p_group_id,v_invite.id,p_actor_id,'INVITATION_REVOKED',
    'pending','revoked',p_reason_code,p_correlation_id,p_occurred_at);
  PERFORM set_config('microfams.group_membership_engine',COALESCE(v_setting,''),TRUE);
  RETURN v_invite.id;
END $$;

ALTER TABLE group_membership_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_membership_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_read ON group_membership_invitations;
CREATE POLICY tenant_read ON group_membership_invitations FOR SELECT
  USING(has_active_organization_membership(organization_id));
DROP POLICY IF EXISTS tenant_read ON group_membership_events;
CREATE POLICY tenant_read ON group_membership_events FOR SELECT
  USING(has_active_organization_membership(organization_id));
REVOKE ALL ON group_membership_invitations,group_membership_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_membership_invitations,group_membership_events TO service_role;
REVOKE INSERT,UPDATE,DELETE ON group_membership_invitations,group_membership_events FROM service_role;
REVOKE ALL ON FUNCTION create_group_membership_invitation(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION accept_group_membership_invitation(UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION revoke_group_membership_invitation(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION create_group_membership_invitation(UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION accept_group_membership_invitation(UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION revoke_group_membership_invitation(UUID,UUID,UUID,UUID,TEXT,UUID,TIMESTAMPTZ) TO service_role;
