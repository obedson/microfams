# Institutional programme reporting scopes

Apply `backend/migrations/install_institutional_programme_reporting_scopes.sql`
through the normal migration runner after the institutional programme foundation.

A programme owner, administrator, or programme manager may request access only
to an explicit list of aggregate metric identifiers for a documented purpose.
The participating organization's owner is the only role that can grant, reject,
or revoke consent. Request and consent evidence is hashed before persistence,
and every transition is written to both organizations' audit logs.

This increment does not expose a cross-tenant query, dashboard, or export.
Downstream reporting must independently verify that the scope is granted,
effective, unexpired, unrevoked, limited to the requested metrics, and protected
against row-level or small-cell disclosure.

To recover, disable `institutional.government_dashboard` to prevent new API
operations. Existing evidence remains readable for authorized servicing. A
rollback must preserve audit and consent history; remove the schema only through
a separately reviewed retention-aware migration.
