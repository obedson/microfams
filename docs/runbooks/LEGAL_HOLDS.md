# Legal Hold Operations Runbook

Before enabling `trust.legal_holds`, apply the migration and verify platform-admin assignments. Use `/admin/trust/legal-holds` to inspect history, place a hold with the correct organization and subject, and release it only with documented authority.

For placement, confirm the subject identifier and tenant scope against the source record. Use a machine-readable reason code and avoid personal, financial, or identity data in notes. Repeating a command must reuse the same idempotency key only when all facts are identical.

For release, independently confirm that the litigation, regulatory, investigation, or audit obligation has ended. Disabling the flag stops new holds but intentionally leaves listing and release operational.

Never edit or delete hold evidence. If a hold was placed incorrectly, release it with a corrective reason. Monitor active-hold counts, failed scope validations, repeated commands, and hold age. The retention worker must fail closed when hold evaluation is unavailable.