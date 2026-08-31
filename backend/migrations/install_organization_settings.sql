-- Tenant-scoped notification and reporting/export policy settings.
SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS organization_settings (
  organization_id UUID PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
  notification_preferences JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(notification_preferences) = 'object'),
  reporting_policy JSONB NOT NULL DEFAULT '{}'::JSONB
    CHECK (jsonb_typeof(reporting_policy) = 'object'),
  updated_by UUID REFERENCES users(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE organization_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON organization_settings FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON organization_settings FROM service_role;
GRANT SELECT ON organization_settings TO service_role;

CREATE OR REPLACE FUNCTION update_organization_settings(
  p_organization_id UUID,
  p_actor_id UUID,
  p_notification_preferences JSONB,
  p_reporting_policy JSONB,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS TABLE (
  notification_preferences JSONB,
  reporting_policy JSONB,
  updated_by UUID,
  updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_before JSONB;
BEGIN
  IF p_organization_id IS NULL
     OR p_actor_id IS NULL
     OR (p_notification_preferences IS NULL AND p_reporting_policy IS NULL)
     OR (p_notification_preferences IS NOT NULL
       AND jsonb_typeof(p_notification_preferences) <> 'object')
     OR (p_reporting_policy IS NOT NULL
       AND jsonb_typeof(p_reporting_policy) <> 'object')
  THEN
    RAISE EXCEPTION 'ORGANIZATION_SETTINGS_COMMAND_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM organizations
    WHERE id = p_organization_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'ORGANIZATION_NOT_ACTIVE';
  END IF;

  PERFORM assert_organization_membership_administrator(
    p_organization_id, p_actor_id
  );

  SELECT jsonb_build_object(
    'notificationPreferences', settings.notification_preferences,
    'reportingPolicy', settings.reporting_policy
  ) INTO v_before
  FROM organization_settings AS settings
  WHERE settings.organization_id = p_organization_id
  FOR UPDATE;

  INSERT INTO organization_settings(
    organization_id, notification_preferences, reporting_policy,
    updated_by, updated_at
  ) VALUES (
    p_organization_id,
    COALESCE(p_notification_preferences, '{}'::JSONB),
    COALESCE(p_reporting_policy, '{}'::JSONB),
    p_actor_id, p_occurred_at
  )
  ON CONFLICT (organization_id) DO UPDATE SET
    notification_preferences = COALESCE(
      p_notification_preferences, organization_settings.notification_preferences
    ),
    reporting_policy = COALESCE(
      p_reporting_policy, organization_settings.reporting_policy
    ),
    updated_by = p_actor_id,
    updated_at = p_occurred_at;

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id,
    before_value, after_value, occurred_at
  )
  SELECT settings.organization_id, p_actor_id, 'organization.settings.updated',
    'organization_settings', settings.organization_id::TEXT, v_before,
    jsonb_build_object(
      'notificationPreferences', settings.notification_preferences,
      'reportingPolicy', settings.reporting_policy
    ),
    p_occurred_at
  FROM organization_settings AS settings
  WHERE settings.organization_id = p_organization_id;

  RETURN QUERY
  SELECT settings.notification_preferences, settings.reporting_policy,
    settings.updated_by, settings.updated_at
  FROM organization_settings AS settings
  WHERE settings.organization_id = p_organization_id;
END;
$$;

REVOKE ALL ON FUNCTION update_organization_settings(UUID,UUID,JSONB,JSONB,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION update_organization_settings(UUID,UUID,JSONB,JSONB,TIMESTAMPTZ)
  TO service_role;
