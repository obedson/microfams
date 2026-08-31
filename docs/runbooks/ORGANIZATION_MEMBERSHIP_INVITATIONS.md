# Organization Membership Invitations

## Scope

This workflow lets organization owners and administrators create, inspect, and revoke tenant-bound invitations. Acceptance is available to an authenticated account before it has tenant context. The database binds acceptance to the normalized account email and stores only a SHA-256 token digest.

The raw token is returned only for the first successful create command. The caller must deliver it through an approved notification channel and must not log, persist, or expose it in analytics.

## Rollout

1. Apply `install_organization_membership_invitations.sql`.
2. Confirm the backend role can execute the three invitation functions.
3. Confirm the backend role cannot insert or update `organization_invitations`, `organization_memberships`, or `organization_audit_log` directly.
4. Deploy the backend routes.
5. Create and revoke a short-lived test invitation in a non-production tenant.
6. Verify `organization.invitation.created` and `organization.invitation.revoked` audit rows.

## Health Evidence

Use tenant-scoped queries and masked email values when gathering evidence.

- Pending invitations have a future `expires_at` and no terminal timestamp.
- Accepted invitations have `accepted_at` and exactly one organization membership.
- Revoked invitations have `revoked_at`.
- Every create, accept, and revoke transition has a matching organization audit row.
- Replaying a create idempotency key does not create another invitation or return another raw token.

Never include `token_hash` in an API response, log, export, or support transcript.

## Recovery

If a raw token is exposed, revoke the pending invitation immediately and issue a new invitation with a new idempotency key. A revoked, expired, or accepted token cannot create another membership.

If acceptance fails after a caller receives a token:

1. Check that the authenticated account email matches the normalized invitation email.
2. Check organization and invitation lifecycle states.
3. Check for an existing non-removed membership.
4. Revoke and recreate the invitation when the intended email or role was wrong.

Do not edit membership or invitation rows manually. Use the command APIs so authorization and audit evidence remain intact.

## Rollback

The migration is additive and its evidence must be preserved. To stop new invitation activity, deploy the previous backend version or remove routing to the command endpoints. Existing accepted memberships remain valid, and existing pending invitations remain unusable without the acceptance endpoint.

Do not drop invitation columns, functions, or audit rows during an incident. A later forward migration may revoke function execution after confirming that no supported backend version still calls them.
