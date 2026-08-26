# Inventory Operations and Recovery

## Scope

Inventory is tenant-scoped. Authorized organization operators can list items, create items, and record positive or negative stock movements. Every movement requires a reason and idempotency key; negative stock is rejected.

This increment covers the web inventory workflow. Warehouses, equipment maintenance, internal resource booking, and utilization remain separate Phase 6 work.

## Deployment verification

1. Enable the backend farm operations flag for the target organization.
2. Open `/inventory` as an authorized owner, administrator, or programme manager.
3. Create an item with a unit and reorder level.
4. Record a positive or negative movement with a reason and verify the resulting stock.
5. Confirm the active organization header is present and cross-tenant reads/mutations are denied.

## Monitoring

Track inventory list/create/movement errors by tenant and correlation identifier. Alert on repeated negative-stock rejections, idempotency conflicts, or unexpected database no-row results. Do not log sensitive metadata or operator notes.

## Disable and recovery

Disable new inventory mutations by removing the tenant's backend farm operations enablement before an unsafe application rollback. Existing inventory remains readable for reconciliation and support. Do not delete or rewrite movements. Correct stock through a compensating movement with a new idempotency key or a forward migration; preserve the original reason and audit evidence.

A rollback record must include the commit, tenant, time, reason, affected item identifiers, and verification result.
