# Legal Hold Commands

## Authority and scope

Only active platform administrators may place or release legal holds. Holds may be global or organization-scoped and target a user, organization, membership, trust case, or retention data class. PostgreSQL validates that organization-scoped subjects belong to the stated organization; global and tenant resources cannot be silently mixed.

## Lifecycle

Placement requires a structured reason code, optional bounded note, and idempotency key. Only one active hold may exist for the same organization/subject tuple. Placement evidence is immutable. Release is the only permitted update and requires a separate structured reason, actor, timestamp, optional note, and idempotency key. A released hold is never reactivated; a later obligation creates a new hold.

`trust.legal_holds` gates new placement and defaults off. Listing and release remain available when the flag is disabled so active obligations are visible and can be lawfully ended.

## Retention interaction

An active matching hold must cause the retention item-selection worker to classify data as `held`; it must never be proposed for anonymization or deletion. This increment establishes authoritative hold state and history. The separate retention selection worker remains the next follow-up, and destructive retention remains unavailable.

## Security and recovery

Tables deny direct client access. Placement/release RPCs require service-role execution and platform-admin authority. Events and placement facts are append-only. Corrections use release plus a new hold. Rollback disables new placement and preserves existing holds, events, and release access.