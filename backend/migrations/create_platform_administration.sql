-- Explicit platform administration and account suspension controls.
BEGIN;

ALTER TABLE users ADD COLUMN IF NOT EXISTS is_suspended BOOLEAN;
UPDATE users SET is_suspended = FALSE WHERE is_suspended IS NULL;
ALTER TABLE users ALTER COLUMN is_suspended SET DEFAULT FALSE;
ALTER TABLE users ALTER COLUMN is_suspended SET NOT NULL;

CREATE TABLE platform_administrator_assignments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  granted_by UUID REFERENCES users(id) ON DELETE SET NULL,
  grant_reason_code TEXT NOT NULL CHECK (grant_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  revoked_by UUID REFERENCES users(id) ON DELETE SET NULL,
  revoked_at TIMESTAMPTZ,
  revocation_reason_code TEXT,
  CHECK (expires_at IS NULL OR expires_at > granted_at),
  CHECK (
    (status = 'active' AND revoked_at IS NULL AND revoked_by IS NULL AND revocation_reason_code IS NULL)
    OR
    (status = 'revoked' AND revoked_at IS NOT NULL AND revocation_reason_code IS NOT NULL)
  )
);

CREATE UNIQUE INDEX uq_active_platform_administrator
  ON platform_administrator_assignments(user_id) WHERE status = 'active';
CREATE INDEX idx_platform_administrator_status
  ON platform_administrator_assignments(status, expires_at);

CREATE TABLE user_account_suspensions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'lifted')),
  reason_code TEXT NOT NULL CHECK (reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  reason_note TEXT CHECK (reason_note IS NULL OR char_length(reason_note) <= 1000),
  suspended_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  suspended_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  lifted_by UUID REFERENCES users(id) ON DELETE RESTRICT,
  lifted_at TIMESTAMPTZ,
  lift_reason_code TEXT,
  CHECK (
    (status = 'active' AND lifted_at IS NULL AND lifted_by IS NULL AND lift_reason_code IS NULL)
    OR
    (status = 'lifted' AND lifted_at IS NOT NULL AND lifted_by IS NOT NULL
      AND lift_reason_code ~ '^[A-Z][A-Z0-9_]{2,63}$')
  )
);

CREATE UNIQUE INDEX uq_active_user_account_suspension
  ON user_account_suspensions(user_id) WHERE status = 'active';
CREATE INDEX idx_user_account_suspension_history
  ON user_account_suspensions(user_id, suspended_at DESC);

CREATE TABLE platform_administration_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN (
    'platform_admin.granted',
    'platform_admin.revoked',
    'user.suspended',
    'user.resumed'
  )),
  target_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  resource_id UUID,
  reason_code TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(metadata) = 'object'),
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_platform_administration_events
  ON platform_administration_events(occurred_at DESC, action);
CREATE INDEX idx_platform_administration_target_events
  ON platform_administration_events(target_user_id, occurred_at DESC);

CREATE OR REPLACE FUNCTION protect_platform_administration_history() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'Platform administration audit history is immutable';
END;
$$;

CREATE OR REPLACE FUNCTION protect_platform_administrator_assignment() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE'
    AND OLD.status = 'active'
    AND NEW.status = 'revoked'
    AND (to_jsonb(OLD) - 'status' - 'revoked_by' - 'revoked_at' - 'revocation_reason_code')
      = (to_jsonb(NEW) - 'status' - 'revoked_by' - 'revoked_at' - 'revocation_reason_code')
  THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Platform administrator assignment history is immutable';
END;
$$;

CREATE OR REPLACE FUNCTION protect_user_account_suspension() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE'
    AND OLD.status = 'active'
    AND NEW.status = 'lifted'
    AND (to_jsonb(OLD) - 'status' - 'lifted_by' - 'lifted_at' - 'lift_reason_code')
      = (to_jsonb(NEW) - 'status' - 'lifted_by' - 'lifted_at' - 'lift_reason_code')
  THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Account suspension history is immutable';
END;
$$;

CREATE TRIGGER platform_administration_events_append_only
  BEFORE UPDATE OR DELETE ON platform_administration_events
  FOR EACH ROW EXECUTE FUNCTION protect_platform_administration_history();
CREATE TRIGGER platform_administrator_assignments_history
  BEFORE UPDATE OR DELETE ON platform_administrator_assignments
  FOR EACH ROW EXECUTE FUNCTION protect_platform_administrator_assignment();
CREATE TRIGGER user_account_suspensions_history
  BEFORE UPDATE OR DELETE ON user_account_suspensions
  FOR EACH ROW EXECUTE FUNCTION protect_user_account_suspension();

CREATE OR REPLACE FUNCTION is_active_platform_administrator(p_user_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM platform_administrator_assignments assignment
    JOIN users subject ON subject.id = assignment.user_id
    WHERE assignment.user_id = p_user_id
      AND assignment.status = 'active'
      AND (assignment.expires_at IS NULL OR assignment.expires_at > NOW())
      AND subject.is_suspended = FALSE
  );
$$;

CREATE OR REPLACE FUNCTION grant_platform_administrator(
  p_actor_id UUID,
  p_user_id UUID,
  p_reason_code TEXT,
  p_expires_at TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_assignment platform_administrator_assignments;
BEGIN
  IF NOT is_active_platform_administrator(p_actor_id) THEN
    RAISE EXCEPTION 'Active platform administrator authority is required';
  END IF;
  IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' THEN
    RAISE EXCEPTION 'Grant reason code is invalid';
  END IF;
  IF p_expires_at IS NOT NULL AND p_expires_at <= NOW() THEN
    RAISE EXCEPTION 'Administrator assignment expiry must be in the future';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND is_suspended = FALSE) THEN
    RAISE EXCEPTION 'Eligible platform administrator user not found';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('platform-admin:' || p_user_id::TEXT, 0));
  UPDATE platform_administrator_assignments SET
    status = 'revoked',
    revoked_by = p_actor_id,
    revoked_at = NOW(),
    revocation_reason_code = 'ASSIGNMENT_EXPIRED'
  WHERE user_id = p_user_id
    AND status = 'active'
    AND expires_at <= NOW()
  RETURNING * INTO v_assignment;

  IF v_assignment.id IS NOT NULL THEN
    INSERT INTO platform_administration_events(
      actor_id, action, target_user_id, resource_id, reason_code
    ) VALUES (
      p_actor_id, 'platform_admin.revoked', p_user_id, v_assignment.id,
      'ASSIGNMENT_EXPIRED'
    );
    v_assignment := NULL;
  END IF;

  SELECT * INTO v_assignment
  FROM platform_administrator_assignments
  WHERE user_id = p_user_id AND status = 'active';

  IF v_assignment.id IS NULL THEN
    INSERT INTO platform_administrator_assignments(
      user_id, granted_by, grant_reason_code, expires_at
    ) VALUES (
      p_user_id, p_actor_id, p_reason_code, p_expires_at
    ) RETURNING * INTO v_assignment;

    INSERT INTO platform_administration_events(
      actor_id, action, target_user_id, resource_id, reason_code,
      metadata
    ) VALUES (
      p_actor_id, 'platform_admin.granted', p_user_id, v_assignment.id, p_reason_code,
      jsonb_build_object('expiresAt', p_expires_at)
    );
  END IF;

  RETURN jsonb_build_object(
    'id', v_assignment.id,
    'userId', v_assignment.user_id,
    'status', v_assignment.status,
    'grantedAt', v_assignment.granted_at,
    'expiresAt', v_assignment.expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION revoke_platform_administrator(
  p_actor_id UUID,
  p_user_id UUID,
  p_reason_code TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_assignment platform_administrator_assignments;
  v_active_count INTEGER;
BEGIN
  IF NOT is_active_platform_administrator(p_actor_id) THEN
    RAISE EXCEPTION 'Active platform administrator authority is required';
  END IF;
  IF p_actor_id = p_user_id THEN
    RAISE EXCEPTION 'Platform administrators cannot revoke themselves';
  END IF;
  IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' THEN
    RAISE EXCEPTION 'Revocation reason code is invalid';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('platform-admin-roster', 0));
  SELECT count(*) INTO v_active_count
  FROM platform_administrator_assignments
  WHERE status = 'active' AND (expires_at IS NULL OR expires_at > NOW());

  SELECT * INTO v_assignment
  FROM platform_administrator_assignments
  WHERE user_id = p_user_id AND status = 'active'
  FOR UPDATE;

  IF v_assignment.id IS NULL THEN
    RETURN jsonb_build_object('userId', p_user_id, 'status', 'revoked');
  END IF;
  IF v_active_count <= 1 THEN
    RAISE EXCEPTION 'The last active platform administrator cannot be revoked';
  END IF;

  UPDATE platform_administrator_assignments SET
    status = 'revoked',
    revoked_by = p_actor_id,
    revoked_at = NOW(),
    revocation_reason_code = p_reason_code
  WHERE id = v_assignment.id
  RETURNING * INTO v_assignment;

  INSERT INTO platform_administration_events(
    actor_id, action, target_user_id, resource_id, reason_code
  ) VALUES (
    p_actor_id, 'platform_admin.revoked', p_user_id, v_assignment.id, p_reason_code
  );

  RETURN jsonb_build_object(
    'id', v_assignment.id,
    'userId', v_assignment.user_id,
    'status', v_assignment.status,
    'revokedAt', v_assignment.revoked_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION suspend_platform_user(
  p_actor_id UUID,
  p_user_id UUID,
  p_reason_code TEXT,
  p_reason_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_suspension user_account_suspensions;
  v_assignment platform_administrator_assignments;
  v_active_count INTEGER;
BEGIN
  IF NOT is_active_platform_administrator(p_actor_id) THEN
    RAISE EXCEPTION 'Active platform administrator authority is required';
  END IF;
  IF p_actor_id = p_user_id THEN
    RAISE EXCEPTION 'Platform administrators cannot suspend themselves';
  END IF;
  IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' THEN
    RAISE EXCEPTION 'Suspension reason code is invalid';
  END IF;
  IF p_reason_note IS NOT NULL AND char_length(p_reason_note) > 1000 THEN
    RAISE EXCEPTION 'Suspension reason note is too long';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'User not found';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('platform-admin-roster', 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('account-suspension:' || p_user_id::TEXT, 0));

  SELECT * INTO v_suspension
  FROM user_account_suspensions
  WHERE user_id = p_user_id AND status = 'active';

  IF v_suspension.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'id', v_suspension.id,
      'userId', v_suspension.user_id,
      'status', v_suspension.status,
      'reasonCode', v_suspension.reason_code,
      'suspendedAt', v_suspension.suspended_at
    );
  END IF;

  SELECT * INTO v_assignment
  FROM platform_administrator_assignments
  WHERE user_id = p_user_id
    AND status = 'active'
    AND (expires_at IS NULL OR expires_at > NOW())
  FOR UPDATE;

  IF v_assignment.id IS NOT NULL THEN
    SELECT count(*) INTO v_active_count
    FROM platform_administrator_assignments
    WHERE status = 'active' AND (expires_at IS NULL OR expires_at > NOW());
    IF v_active_count <= 1 THEN
      RAISE EXCEPTION 'The last active platform administrator cannot be suspended';
    END IF;

    UPDATE platform_administrator_assignments SET
      status = 'revoked',
      revoked_by = p_actor_id,
      revoked_at = NOW(),
      revocation_reason_code = 'ACCOUNT_SUSPENDED'
    WHERE id = v_assignment.id;

    INSERT INTO platform_administration_events(
      actor_id, action, target_user_id, resource_id, reason_code
    ) VALUES (
      p_actor_id, 'platform_admin.revoked', p_user_id, v_assignment.id, 'ACCOUNT_SUSPENDED'
    );
  END IF;

  INSERT INTO user_account_suspensions(
    user_id, reason_code, reason_note, suspended_by
  ) VALUES (
    p_user_id, p_reason_code, NULLIF(trim(p_reason_note), ''), p_actor_id
  ) RETURNING * INTO v_suspension;

  UPDATE users SET is_suspended = TRUE, updated_at = NOW() WHERE id = p_user_id;
  UPDATE refresh_tokens SET revoked = TRUE WHERE user_id = p_user_id AND revoked = FALSE;

  INSERT INTO platform_administration_events(
    actor_id, action, target_user_id, resource_id, reason_code
  ) VALUES (
    p_actor_id, 'user.suspended', p_user_id, v_suspension.id, p_reason_code
  );

  RETURN jsonb_build_object(
    'id', v_suspension.id,
    'userId', v_suspension.user_id,
    'status', v_suspension.status,
    'reasonCode', v_suspension.reason_code,
    'suspendedAt', v_suspension.suspended_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION resume_platform_user(
  p_actor_id UUID,
  p_user_id UUID,
  p_reason_code TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_suspension user_account_suspensions;
BEGIN
  IF NOT is_active_platform_administrator(p_actor_id) THEN
    RAISE EXCEPTION 'Active platform administrator authority is required';
  END IF;
  IF p_reason_code !~ '^[A-Z][A-Z0-9_]{2,63}$' THEN
    RAISE EXCEPTION 'Resumption reason code is invalid';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'User not found';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('account-suspension:' || p_user_id::TEXT, 0));
  SELECT * INTO v_suspension
  FROM user_account_suspensions
  WHERE user_id = p_user_id AND status = 'active'
  FOR UPDATE;

  IF v_suspension.id IS NULL THEN
    UPDATE users SET is_suspended = FALSE, updated_at = NOW()
    WHERE id = p_user_id AND is_suspended = TRUE;
    RETURN jsonb_build_object('userId', p_user_id, 'status', 'active');
  END IF;

  UPDATE user_account_suspensions SET
    status = 'lifted',
    lifted_by = p_actor_id,
    lifted_at = NOW(),
    lift_reason_code = p_reason_code
  WHERE id = v_suspension.id
  RETURNING * INTO v_suspension;

  UPDATE users SET is_suspended = FALSE, updated_at = NOW() WHERE id = p_user_id;

  INSERT INTO platform_administration_events(
    actor_id, action, target_user_id, resource_id, reason_code
  ) VALUES (
    p_actor_id, 'user.resumed', p_user_id, v_suspension.id, p_reason_code
  );

  RETURN jsonb_build_object(
    'id', v_suspension.id,
    'userId', v_suspension.user_id,
    'status', 'active',
    'resumedAt', v_suspension.lifted_at
  );
END;
$$;

ALTER TABLE platform_administrator_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_account_suspensions ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform_administration_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON platform_administrator_assignments, user_account_suspensions,
  platform_administration_events FROM anon, authenticated;
REVOKE ALL ON FUNCTION is_active_platform_administrator(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION grant_platform_administrator(UUID, UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION revoke_platform_administrator(UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION suspend_platform_user(UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION resume_platform_user(UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION is_active_platform_administrator(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION grant_platform_administrator(UUID, UUID, TEXT, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION revoke_platform_administrator(UUID, UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION suspend_platform_user(UUID, UUID, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION resume_platform_user(UUID, UUID, TEXT) TO service_role;

COMMIT;
