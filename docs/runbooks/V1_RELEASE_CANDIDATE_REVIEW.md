# V1 release-candidate review

Status: **NO-GO until every gate is evidenced and reviewed.**

This record is the repeatable review procedure for a Version 1 candidate. It must be updated on the candidate branch for each review; it does not authorize a release or override approved specifications.

## Evidence capture

Run from the Codespace root:

```bash
git rev-parse HEAD
node scripts/reconcile-v1.mjs --check
gh pr checks <PR_NUMBER> -R obedson/microfams
```

Record the exact commit SHA, pull request number, CI run URL, and reconciliation result below. A review is invalid if the reconciliation check is stale or any required CI check is failing.

- Candidate commit: <commit SHA>
- Pull request: #<number>
- CI run: <Actions URL>
- Reconciliation: PASS at <timestamp>
- Reviewer: <GitHub handle>
- Review date: <ISO-8601 date>

## Gate checklist

- [ ] Approved specification is linked for every claimed item.
- [ ] Migration/domain implementation is present and tenant-safe.
- [ ] Authenticated API and required web/mobile workflows are demonstrated.
- [ ] Required unit, integration, API, component, E2E, security, and recovery tests pass.
- [ ] Operational monitoring, reconciliation, disablement, rollback, and recovery evidence is linked.
- [ ] No unresolved release blocker remains in the reconciliation report.

## Decision

The reviewer records **GO** only after every applicable checklist item is evidenced. Otherwise record **NO-GO**, list the blocking work-plan IDs, and keep provider-dependent or regulated capabilities disabled.

## Rollback

If a candidate review exposes a regression, keep the current release deployed, disable the affected backend feature flag, preserve existing records, and revert by forward migration or a reviewed code rollback. Re-run reconciliation and the affected CI suites before the next review.
