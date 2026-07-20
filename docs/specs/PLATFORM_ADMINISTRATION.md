# Platform administration boundary

Status: approved implementation baseline derived from the Version 1 multi-tenancy and trust requirements.

## Purpose

Platform administration is a global security responsibility. It is independent from an
organization membership role. An organization owner or administrator must never gain
platform-wide access merely because their legacy user role is `owner` or `admin`.

## PA-01 Explicit authority

- Global authority is granted only by an active row in
  `platform_administrator_assignments`.
- The legacy `users.role` value is not authorization evidence for platform routes.
- An assignment records its grantor, reason, lifecycle, and optional expiry.
- Existing legacy administrators are not silently promoted during migration.
- The first assignment is a controlled database bootstrap performed with the service
  role and recorded in the operations runbook. Subsequent grants use the audited API.

## PA-02 Separation of duties

- Tenant owners and tenant administrators remain limited to their organizations.
- Platform administrators may use `/api/admin` only while their assignment is active
  and unexpired.
- A platform administrator cannot revoke or suspend their own account.
- The last active platform administrator cannot be revoked or suspended.
- Suspension of another platform administrator revokes that administrator assignment;
  resumption does not restore it automatically.

## PA-03 Account suspension

- A suspension requires a machine-readable reason code and may include a bounded note.
- Suspension creates an immutable history record, sets the user account suspension
  projection, and revokes every refresh token in one database transaction.
- Existing access tokens are checked against current account state on every authenticated
  request. A suspended account receives `ACCOUNT_SUSPENDED`.
- Resumption lifts the active suspension and clears the projection. It does not issue
  new tokens or restore platform authority.
- Repeated commands are safe: suspending an already suspended account and resuming an
  active account return their current state without creating conflicting records.

## PA-04 Audit and privacy

- Grants, revocations, suspensions, and resumptions create append-only platform audit
  events.
- Public API responses expose status and reason codes but never password hashes,
  refresh tokens, identity numbers, provider secrets, or raw financial details.
- Notes are limited to 1,000 characters and must not contain identity numbers or secrets.
- Database access is service-role only; browser and mobile database roles have no direct
  access to administration records.

## PA-05 Recovery and compatibility

- `users.is_suspended` remains as a compatibility projection and is never the audit
  source of truth.
- `user_account_suspensions` is the suspension history source of truth.
- The legacy user role remains temporarily for non-platform product behavior, but
  `/api/admin` no longer trusts it.
- If the platform-administration store is unavailable, platform authorization and
  authenticated account-state checks fail closed.
- Recovery from a lost final administrator requires an explicitly audited service-role
  bootstrap, followed by credential review.

## API contract

- `GET /api/admin/platform-administrators`
- `POST /api/admin/platform-administrators`
- `DELETE /api/admin/platform-administrators/:userId`
- `POST /api/admin/users/:id/suspend`
- `POST /api/admin/users/:id/resume`

All endpoints require an authenticated, active platform-administrator assignment.

## Acceptance evidence

- Unit tests prove authorization, expiry, self-protection, validation, and public mapping.
- API tests prove the controller contract and generic error handling.
- Schema tests prove no implicit legacy promotion, last-administrator protection,
  refresh-token revocation, idempotency, immutable audit history, and direct-access denial.
- Legacy-upgrade testing proves the migration can be applied to the current Supabase
  schema without mutating existing user roles.
