# V1 evidence reconciliation operations

## Purpose

The work-plan checkbox is a delivery claim, not proof. `docs/V1_RECONCILIATION.json` links every Version 1 item to discoverable specification, implementation, API, client, test, and operations evidence. The generated Markdown report is the review index.

Automated discovery is conservative and may produce false positives or gaps. Only reviewed behavior and approved specifications can support release acceptance.

## Status meanings

- `candidate_complete`: the work-plan item is checked and every automatically required layer has at least one evidence path. Manual acceptance is still required.
- `claimed_complete_evidence_gap`: the item is checked but at least one required layer is missing. This blocks acceptance.
- `partial`: implementation evidence exists, but the item is not checked.
- `not_started`: no implementation evidence was discovered.

## Change procedure

1. Identify the stable work-plan ID in `docs/V1_RECONCILIATION.md`.
2. Verify the approved specification and inspect the actual implementation. Do not rely on filenames or a prior checkbox.
3. Add or update the required migrations/domain services, authenticated tenant-safe API, web/mobile workflow, tests, and operations or rollback documentation.
4. Complete the pull-request evidence checklist with repository paths and the relevant CI run.
5. Stage new evidence files before running `node scripts/reconcile-v1.mjs`; discovery considers tracked and staged paths.
6. Run `node scripts/reconcile-v1.mjs --check` and `node --test scripts/reconcile-v1.test.mjs`.
7. Check the work-plan item only after all applicable layers pass review. Commit the generated JSON and Markdown with the implementation.

## Review controls

Reviewers confirm that evidence belongs to the same behavior, tenant boundary, and specification. A matching filename is insufficient. Provider-dependent and regulated workflows also require backend feature flags, credentials/configuration gates, reconciliation, and recovery evidence.

Do not convert `claimed_complete_evidence_gap` to `candidate_complete` by adding unrelated files or weakening layer requirements. Reopen an inaccurate checkbox instead.

## Recovery and rollback

If reconciliation output changes unexpectedly, do not hand-edit generated files. Revert the work-plan or evidence change that caused the drift, rerun the generator, and inspect the exact JSON diff.

If the generator is defective, revert its change and regenerate with the last known-good version. This affects release evidence only; it must never mutate production data or enable a feature. Preserve the failing output and CI run for diagnosis.
