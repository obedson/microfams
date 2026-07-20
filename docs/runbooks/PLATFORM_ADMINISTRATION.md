# Platform administration

Platform administration is global authority and is separate from organization roles.

## Initial bootstrap

The migration intentionally does not promote legacy `users.role = 'admin'` accounts. Select
the first administrator by immutable user ID after verifying the operator and account.

Run the following transaction through an approved service-role database session, replacing
the placeholder UUID:

```sql
BEGIN;

INSERT INTO platform_administrator_assignments(
  user_id, granted_by, grant_reason_code
)
SELECT
  'REPLACE-WITH-VERIFIED-USER-UUID'::UUID,
  NULL,
  'INITIAL_BOOTSTRAP'
WHERE EXISTS (
  SELECT 1 FROM users
  WHERE id = 'REPLACE-WITH-VERIFIED-USER-UUID'::UUID
    AND is_suspended = FALSE
)
AND NOT EXISTS (
  SELECT 1 FROM platform_administrator_assignments
  WHERE status = 'active'
);

INSERT INTO platform_administration_events(
  actor_id, action, target_user_id, reason_code, metadata
)
SELECT
  'REPLACE-WITH-VERIFIED-USER-UUID'::UUID,
  'platform_admin.granted',
  'REPLACE-WITH-VERIFIED-USER-UUID'::UUID,
  'INITIAL_BOOTSTRAP',
  '{"bootstrap":true}'::JSONB
WHERE NOT EXISTS (
  SELECT 1 FROM platform_administration_events
  WHERE action = 'platform_admin.granted'
    AND target_user_id = 'REPLACE-WITH-VERIFIED-USER-UUID'::UUID
);

COMMIT;
```

Confirm with `is_active_platform_administrator(user_id)`. Create at least two
independently controlled platform administrators before production launch.

## Normal operation

After bootstrap, use the authenticated API:

- `GET /api/admin/platform-administrators`
- `POST /api/admin/platform-administrators`
- `DELETE /api/admin/platform-administrators/:userId`
- `POST /api/admin/users/:id/suspend`
- `POST /api/admin/users/:id/resume`

Reason codes use uppercase letters, digits, and underscores. Never place NIN, BVN,
passwords, access tokens, bank details, or provider payloads in a reason note.

Suspension immediately revokes refresh tokens. Existing access tokens are denied on their
next authenticated request. Resumption does not restore a revoked platform-administrator
assignment and does not issue tokens.

## Incident recovery

If all assignments are lost or expired:

1. Treat the event as a privileged-access incident.
2. Verify the recovery operator through an out-of-band process.
3. Re-run the bootstrap transaction with a new reason code such as
   `INCIDENT_RECOVERY` and record the incident identifier in the operational ticket.
4. Review platform administration events and rotate potentially affected credentials.
5. Establish a second administrator.

Do not restore access by changing `users.role` or `users.is_suspended` directly.

## Rollback

Do not drop the administration tables after the feature has been used. Application rollback
may continue reading `users.is_suspended`, but suspension history and audit events must be
retained. A forward fix is required for schema or authorization defects.

## Credentials

No external provider credentials are required. `SUPABASE_DB_URL` is required only for the
legacy-schema upgrade dry run and must be stored as a GitHub Codespaces secret.
