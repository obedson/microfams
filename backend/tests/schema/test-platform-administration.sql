-- Platform administration invariants and suspension lifecycle.
DO $$
DECLARE
  v_actor UUID := '00000000-0000-4000-8000-000000000101';
  v_target UUID := '00000000-0000-4000-8000-000000000102';
  v_legacy_admin UUID := '00000000-0000-4000-8000-000000000120';
  v_expired_admin UUID := '00000000-0000-4000-8000-000000000121';
  v_result JSONB;
  v_event UUID;
BEGIN
  INSERT INTO users(id, email, password, name, role)
  VALUES (
    v_legacy_admin,
    'legacy-platform-admin@example.test',
    'not-a-real-password',
    'Legacy Admin',
    'admin'
  );

  IF is_active_platform_administrator(v_legacy_admin) THEN
    RAISE EXCEPTION 'Legacy admin role was implicitly promoted';
  END IF;

  -- The first grant is an explicit service-role bootstrap with matching audit evidence.
  INSERT INTO platform_administrator_assignments(
    user_id, granted_by, grant_reason_code
  ) VALUES (
    v_actor, NULL, 'INITIAL_BOOTSTRAP'
  );
  INSERT INTO platform_administration_events(
    actor_id, action, target_user_id, reason_code,
    metadata
  ) VALUES (
    v_actor, 'platform_admin.granted', v_actor, 'INITIAL_BOOTSTRAP',
    '{"bootstrap":true}'::JSONB
  );

  IF NOT is_active_platform_administrator(v_actor) THEN
    RAISE EXCEPTION 'Explicit platform administrator is not active';
  END IF;

  INSERT INTO users(id, email, password, name, role)
  VALUES (
    v_expired_admin,
    'expired-platform-admin@example.test',
    'not-a-real-password',
    'Expired Admin',
    'farmer'
  );
  INSERT INTO platform_administrator_assignments(
    user_id, granted_by, grant_reason_code, granted_at, expires_at
  ) VALUES (
    v_expired_admin, v_actor, 'TEMPORARY_ACCESS',
    NOW() - INTERVAL '2 days', NOW() - INTERVAL '1 day'
  );
  PERFORM grant_platform_administrator(
    v_actor, v_expired_admin, 'ACCESS_RENEWED', NULL
  );
  IF (
    SELECT count(*) FROM platform_administrator_assignments
    WHERE user_id = v_expired_admin AND status = 'active'
      AND (expires_at IS NULL OR expires_at > NOW())
  ) <> 1 THEN
    RAISE EXCEPTION 'Expired platform administrator assignment was not renewed safely';
  END IF;

  v_result := grant_platform_administrator(
    v_actor, v_target, 'SECURITY_OPERATIONS', NULL
  );
  IF v_result->>'status' <> 'active' THEN
    RAISE EXCEPTION 'Platform administrator grant failed';
  END IF;

  PERFORM grant_platform_administrator(
    v_actor, v_target, 'SECURITY_OPERATIONS', NULL
  );
  IF (
    SELECT count(*) FROM platform_administrator_assignments
    WHERE user_id = v_target AND status = 'active'
  ) <> 1 THEN
    RAISE EXCEPTION 'Repeated administrator grant was not idempotent';
  END IF;

  INSERT INTO refresh_tokens(user_id, token, expires_at)
  VALUES (v_target, 'schema-platform-admin-refresh', NOW() + INTERVAL '1 day');

  v_result := suspend_platform_user(
    v_actor, v_target, 'SECURITY_REVIEW', 'Test-only bounded reason'
  );
  IF v_result->>'status' <> 'active'
    OR NOT (SELECT is_suspended FROM users WHERE id = v_target)
    OR NOT (SELECT revoked FROM refresh_tokens WHERE token = 'schema-platform-admin-refresh')
  THEN
    RAISE EXCEPTION 'Suspension did not update account and refresh-token projections';
  END IF;
  IF EXISTS (
    SELECT 1 FROM platform_administrator_assignments
    WHERE user_id = v_target AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Suspended platform administrator retained global authority';
  END IF;

  PERFORM suspend_platform_user(
    v_actor, v_target, 'SECURITY_REVIEW', 'Repeated command'
  );
  IF (
    SELECT count(*) FROM user_account_suspensions
    WHERE user_id = v_target AND status = 'active'
  ) <> 1 THEN
    RAISE EXCEPTION 'Repeated suspension created conflicting active history';
  END IF;

  v_result := resume_platform_user(v_actor, v_target, 'REVIEW_COMPLETED');
  IF v_result->>'status' <> 'active'
    OR (SELECT is_suspended FROM users WHERE id = v_target)
  THEN
    RAISE EXCEPTION 'Resumption did not restore account access';
  END IF;
  IF EXISTS (
    SELECT 1 FROM platform_administrator_assignments
    WHERE user_id = v_target AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Resumption silently restored platform authority';
  END IF;

  BEGIN
    PERFORM revoke_platform_administrator(v_actor, v_actor, 'SELF_REVOKE');
    RAISE EXCEPTION 'Platform administrator self-revocation was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'Platform administrator self-revocation was accepted' THEN RAISE; END IF;
  END;

  SELECT id INTO v_event
  FROM platform_administration_events
  WHERE action = 'user.suspended' AND target_user_id = v_target
  LIMIT 1;
  BEGIN
    UPDATE platform_administration_events
    SET reason_code = 'TAMPERED'
    WHERE id = v_event;
    RAISE EXCEPTION 'Platform administration event mutation was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'Platform administration event mutation was accepted' THEN RAISE; END IF;
  END;

  IF has_table_privilege('authenticated', 'platform_administrator_assignments', 'SELECT')
    OR has_table_privilege('authenticated', 'user_account_suspensions', 'SELECT')
    OR has_table_privilege('authenticated', 'platform_administration_events', 'SELECT')
  THEN
    RAISE EXCEPTION 'Authenticated database role has direct platform administration access';
  END IF;
END $$;
