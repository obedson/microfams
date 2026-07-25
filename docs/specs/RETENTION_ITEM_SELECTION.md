# Retention Dry-Run Item Selection

## Purpose and safety boundary

This workflow turns a planned retention run into an immutable preview of records affected by one enabled policy. It never changes, anonymizes, or deletes source data. Destructive execution remains unavailable and is controlled separately by `trust.retention.execute`, which defaults off.

## Supported selector registry

Version 1 begins with an explicit, reviewed registry:

- `trust.case_metadata` selects `trust_review_cases` by `opened_at` and emits resource type `trust_case`.
- `trust.appeal_metadata` selects `trust_appeals` by `filed_at` and emits resource type `trust_appeal`.

Dynamic table names and arbitrary SQL are prohibited. A policy for an unsupported data class fails closed before items are written. New classes require a migration, tenant-ownership review, legal-hold mapping, and schema tests.

## Eligibility and classification

A record is eligible when its source timestamp is earlier than `now - retention_days` and its organization matches the run scope using null-safe equality. The policy must exist, be enabled, and match that same scope.

Classification is deterministic:

- Any active matching case or data-class legal hold produces `held` with `ACTIVE_LEGAL_HOLD`.
- A `review` disposition produces `retain` with `MANUAL_REVIEW_REQUIRED`.
- An `anonymize` disposition produces `would_anonymize`.
- A `delete` disposition produces `would_delete`.

For appeals, a hold on the parent trust case also holds the appeal. A case-specific hold takes evidence precedence over a data-class hold.

## Execution and evidence

Only platform administrators may select items. The command is serialized per run and idempotent per actor/key/request hash. It records the policy, data class, source timestamp, and matching legal hold on each item, then terminally completes the run with summary counts. Run items are append-only and completed runs are immutable.

Creating a new run is gated by `trust.retention.dry_run`. Completing an already planned run remains available if the flag is later disabled, preventing stranded operational evidence. Client roles have no direct table or RPC access.

## Failure and recovery

Disabled, missing, cross-scope, unsupported, or terminal runs are rejected without source mutation. Database or legal-hold evaluation failures roll back the transaction. Operators may retry a failed request with the same idempotency key and facts; changing facts requires a new key. Rollback of the product capability disables new dry-run creation but preserves completed evidence.