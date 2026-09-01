# Phase 0 secret remediation and evidence

Status: **open external release blocker** under WP-P0-001.

Repository changes can prevent new secret exposure and can scan reachable Git objects. They cannot rotate a credential, revoke a provider token, invalidate a session, remove a secret from forks or caches, or prove that an external control-plane action occurred.

## Redacted audit snapshot

A read-only Gitleaks v8.30.1 audit was run on 2026-09-01 from base commit `ab3728d8b17dbb0ea6bcd1162c4b493759167ee7`.

- Reachable-history scan: 554 commits, 72 redacted findings across 35 commits and 28 files.
- Rule distribution: 56 generic API-key, 10 curl authorization-header, 4 JWT, and 2 Sendinblue/Brevo token findings.
- Clean tracked-tree archive: 43 redacted findings, comprising 41 generic API-key and 2 curl authorization-header findings. Most occur in test fixtures, but every finding still requires explicit triage before an allowlist is introduced.
- Historical JWT and Sendinblue/Brevo findings require credential-owner validation and rotation or revocation evidence. Their removal from the current tree is not proof that the issued credentials are inactive.

The raw reports are deliberately not committed because they can contain sensitive metadata. These counts are audit leads, not a declaration that every finding is a live secret.

## Code and repository actions

These actions can be completed through reviewed pull requests:

1. Maintain a value-free inventory of secret names and purposes.
2. Keep production values in protected environment-scoped secret managers.
3. Scan the current tree and reachable history with an approved secret scanner.
4. Block newly introduced credentials in CI.
5. Remove committed values from the current tree.
6. If history rewriting is approved, prepare and independently review the exact object-removal plan before executing it.
7. Document configuration validation, safe defaults, rollback and provider disablement.

A passing scan is evidence only for the scanner, rules and reachable objects used in that run. It is not rotation or revocation evidence.

## External security and operations actions

An authorized owner must complete these outside the repository:

1. Identify every affected credential, provider account, environment and data scope without copying secret values into tickets or Git.
2. Revoke or rotate each credential at its issuing provider.
3. Invalidate affected sessions, webhook signing keys, certificates or deployment tokens where applicable.
4. Update protected development, staging and production secret stores.
5. Restart or redeploy consumers and verify old credentials no longer work.
6. Review provider access and audit logs for use during the exposure window.
7. Decide whether Git history rewriting is required. Record the legal, operational and fork/cache containment decision.
8. Notify affected operators and complete incident or breach procedures required by policy.

## Safe completion evidence

WP-P0-001 remains unchecked until the release reviewer can link a protected incident or change record containing:

- credential name or opaque inventory ID, never its value;
- issuing system and affected environments;
- rotation or revocation timestamp;
- responsible owner and independent reviewer;
- old-credential rejection result;
- protected-store update and service-recovery result;
- history-remediation or approved-containment decision;
- monitoring and incident disposition;
- links to passing current-tree and reachable-history scans.

Do not place credential values, raw scanner findings, provider response bodies, or sensitive audit logs in this repository.
