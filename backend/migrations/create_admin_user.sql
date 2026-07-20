-- RETIRED: users.role does not grant platform-administrator authority.
-- Do not update a user role to obtain global access.
--
-- Follow docs/runbooks/PLATFORM_ADMINISTRATION.md for the controlled,
-- audited initial bootstrap. Subsequent grants must use the platform
-- administration API.
DO $$
BEGIN
  RAISE EXCEPTION 'create_admin_user.sql is retired; use the platform administration runbook';
END $$;
