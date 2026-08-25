# Inventory Foundation

The inventory foundation is tenant-scoped and guarded by the `farm_erp.operations` backend flag. Items store integer quantities in declared units; movements are append-only and require a tenant-scoped idempotency key. Negative resulting stock is rejected.

Apply `backend/migrations/install_inventory_foundation.sql` through the normal migration runner. Roll back by disabling the feature flag, stopping new movements, exporting affected rows, and applying a reviewed migration only after retention and reconciliation checks. Never edit production tables manually.

This increment does not claim warehouse reservations, equipment maintenance, depreciation, or utilization dashboards; those remain separate WP-P6-002 work.
