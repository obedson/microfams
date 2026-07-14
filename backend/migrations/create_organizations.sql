-- Multi-tenant organization foundation for Micro Fams V1.

CREATE TABLE IF NOT EXISTS organizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL CHECK (char_length(trim(name)) BETWEEN 2 AND 160),
  legal_name TEXT,
  slug TEXT NOT NULL UNIQUE CHECK (slug = lower(slug) AND slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  type TEXT NOT NULL CHECK (type IN ('farm_business', 'cooperative', 'ngo', 'government_program', 'agribusiness')),
  jurisdiction CHAR(2) NOT NULL DEFAULT 'NG' CHECK (jurisdiction = upper(jurisdiction)),
  default_currency CHAR(3) NOT NULL DEFAULT 'NGN' CHECK (default_currency = upper(default_currency)),
  timezone TEXT NOT NULL DEFAULT 'Africa/Lagos',
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'closed')),
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(metadata) = 'object'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS organization_branding (
  organization_id UUID PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
  display_name TEXT,
  logo_url TEXT,
  primary_color TEXT CHECK (primary_color IS NULL OR primary_color ~ '^#[0-9A-Fa-f]{6}$'),
  secondary_color TEXT CHECK (secondary_color IS NULL OR secondary_color ~ '^#[0-9A-Fa-f]{6}$'),
  support_email TEXT,
  support_phone TEXT,
  custom_domain TEXT,
  updated_by UUID REFERENCES users(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS organization_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'finance_manager', 'program_manager', 'farm_manager', 'auditor', 'member', 'viewer')),
  permissions TEXT[] NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('invited', 'active', 'suspended', 'removed')),
  invited_by UUID REFERENCES users(id) ON DELETE SET NULL,
  joined_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, user_id)
);

CREATE TABLE IF NOT EXISTS organization_invitations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'finance_manager', 'program_manager', 'farm_manager', 'auditor', 'member', 'viewer')),
  permissions TEXT[] NOT NULL DEFAULT '{}',
  token_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'revoked', 'expired')),
  invited_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  accepted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (expires_at > created_at)
);

CREATE TABLE IF NOT EXISTS organization_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL,
  resource_type TEXT NOT NULL,
  resource_id TEXT,
  before_value JSONB,
  after_value JSONB,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_organization_memberships_user
  ON organization_memberships(user_id, status);
CREATE INDEX IF NOT EXISTS idx_organization_memberships_organization
  ON organization_memberships(organization_id, status, role);
CREATE INDEX IF NOT EXISTS idx_organization_invitations_lookup
  ON organization_invitations(organization_id, lower(email), status);
CREATE INDEX IF NOT EXISTS idx_organization_audit_lookup
  ON organization_audit_log(organization_id, occurred_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_organization_pending_invitation
  ON organization_invitations(organization_id, lower(email)) WHERE status = 'pending';

-- Give every existing user an isolated personal workspace so migration does not
-- force unrelated legacy users into one shared tenant. Domain data is backfilled
-- to these workspaces in domain-specific isolation migrations.
INSERT INTO organizations(id, name, slug, type, created_by)
SELECT
  users.id,
  COALESCE(NULLIF(trim(users.name), ''), split_part(users.email, '@', 1)) || ' Workspace',
  'legacy-' || replace(users.id::TEXT, '-', ''),
  'farm_business',
  users.id
FROM users
ON CONFLICT (id) DO NOTHING;

INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
SELECT users.id, users.id, 'owner', 'active', NOW()
FROM users
ON CONFLICT (organization_id, user_id) DO NOTHING;

CREATE OR REPLACE FUNCTION provision_personal_organization() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO organizations(id, name, slug, type, created_by)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(trim(NEW.name), ''), split_part(NEW.email, '@', 1)) || ' Workspace',
    'legacy-' || replace(NEW.id::TEXT, '-', ''),
    'farm_business',
    NEW.id
  )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO organization_memberships(organization_id, user_id, role, status, joined_at)
  VALUES (NEW.id, NEW.id, 'owner', 'active', NOW())
  ON CONFLICT (organization_id, user_id) DO NOTHING;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS provision_user_personal_organization ON users;
CREATE TRIGGER provision_user_personal_organization
  AFTER INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION provision_personal_organization();

CREATE OR REPLACE FUNCTION create_organization(
  p_user_id UUID,
  p_name TEXT,
  p_legal_name TEXT,
  p_slug TEXT,
  p_type TEXT,
  p_jurisdiction TEXT,
  p_default_currency TEXT,
  p_timezone TEXT
) RETURNS UUID AS $$
DECLARE
  v_organization_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'Organization owner does not exist';
  END IF;

  INSERT INTO organizations(
    name, legal_name, slug, type, jurisdiction, default_currency, timezone, created_by
  ) VALUES (
    trim(p_name), NULLIF(trim(p_legal_name), ''), lower(trim(p_slug)), p_type,
    upper(p_jurisdiction), upper(p_default_currency), p_timezone, p_user_id
  ) RETURNING id INTO v_organization_id;

  INSERT INTO organization_memberships(
    organization_id, user_id, role, status, joined_at
  ) VALUES (
    v_organization_id, p_user_id, 'owner', 'active', NOW()
  );

  INSERT INTO organization_audit_log(
    organization_id, actor_id, action, resource_type, resource_id, after_value
  ) VALUES (
    v_organization_id, p_user_id, 'organization.created', 'organization',
    v_organization_id::TEXT,
    jsonb_build_object('name', trim(p_name), 'type', p_type, 'jurisdiction', upper(p_jurisdiction))
  );

  RETURN v_organization_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION create_organization(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION create_organization(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  TO service_role;

ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_branding ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_audit_log ENABLE ROW LEVEL SECURITY;

-- All tenant access currently flows through the trusted backend, which verifies
-- membership before setting request context. No browser/mobile client may query
-- these tables directly with an anon or authenticated Supabase key.
REVOKE ALL ON organizations, organization_branding, organization_memberships,
  organization_invitations, organization_audit_log FROM anon, authenticated;
