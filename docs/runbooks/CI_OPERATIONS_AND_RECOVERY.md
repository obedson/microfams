# CI Operations and Recovery

This runbook defines the release evidence and recovery procedure for the GitHub Actions checks required by Version 1. It applies to pull requests, `main`, and release-candidate validation.

## Required checks

Every pull request must pass Backend, Backend database integration, Hosted legacy schema upgrade, Frontend, Browser E2E smoke, Mobile, Repository dependency audit, and Repository security. Vercel preview checks must also complete when a frontend change is included. A draft pull request is not release evidence until all required checks are green for the final commit.

The reconciliation report must be current. Run `node scripts/reconcile-v1.mjs --check` locally before pushing changes that affect specifications, migrations, tests, or work-plan evidence.

## Triage and reruns

1. Open the failed job and record the workflow run, job, commit SHA, tenant or environment, and correlation ID where applicable.
2. Classify the failure as code, test data, migration/database, credential/configuration, dependency/security, provider, or infrastructure.
3. Rerun only after confirming the failure is transient. Do not rerun a deterministic test or schema failure to manufacture a green result.
4. For a code or migration failure, fix the branch and push a new commit. Preserve the failing run URL in the pull request notes.
5. For a credential failure, do not print or commit secrets. Restore the required Codespaces/Actions secret, rerun the job, and record only the secret name and timestamp.

## Database and migration failures

Backend database integration uses an isolated Supabase environment. A missing or shared `SUPABASE_URL`/`SUPABASE_SERVICE_KEY` is a configuration incident; stop the run and repair the secret rather than pointing CI at production. Hosted legacy schema upgrade requires `SUPABASE_DB_URL` and must be treated as a migration rehearsal. Never repair a failed migration by editing the hosted database manually. Correct the migration, test it against a disposable database, and rerun from the original commit.

## Security and dependency failures

Backend and frontend run production-only `npm audit`; the repository job audits the supported dependency trees. Mobile uses `mobile/scripts/audit-production.mjs` and fails on critical or unapproved high findings. Do not suppress a new advisory by expanding an allow-list without documenting the package, severity, reachability, remediation status, and review date. Secret-scan findings require immediate rotation and history review before the check is rerun.

## Deployment and rollback

Treat a failed Vercel deployment or preview as a release blocker for frontend changes. Inspect the deployment logs and commit SHA, then redeploy the last known-good commit through the normal provider controls. Application rollback does not roll back database migrations: use a forward-compatible migration or an approved compensating migration, and preserve financial records through reversals rather than deletion. Disable the affected backend feature flag to stop new operations while retaining existing evidence.

## Incident evidence and recovery

For every release-blocking incident, retain the run URL, failed job, commit SHA, UTC timestamps, affected tenant/environment, error classification, mitigation, and verification result. After recovery, rerun the complete required check set on the exact release commit. A release candidate is accepted only when all checks pass, reconciliation is current, and the recovery record is linked from the release notes or deployment record.

## Escalation

Escalate immediately when production credentials, personal data, financial postings, webhook verification, tenant isolation, or an irreversible migration may be affected. Pause new operations with the relevant feature flag, preserve logs and audit evidence, and involve the platform and domain owners before resuming.
