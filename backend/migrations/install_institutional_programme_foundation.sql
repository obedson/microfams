CREATE TABLE IF NOT EXISTS institutional_programmes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  description TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','closed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS institutional_programme_cohorts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  programme_id UUID NOT NULL REFERENCES institutional_programmes(id),
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  starts_on DATE,
  ends_on DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on)
);
CREATE TABLE IF NOT EXISTS institutional_programme_benefits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id),
  programme_id UUID NOT NULL REFERENCES institutional_programmes(id),
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  description TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_institutional_programmes_org ON institutional_programmes(organization_id);
CREATE INDEX IF NOT EXISTS idx_institutional_cohorts_programme ON institutional_programme_cohorts(organization_id, programme_id);
CREATE INDEX IF NOT EXISTS idx_institutional_benefits_programme ON institutional_programme_benefits(organization_id, programme_id);
