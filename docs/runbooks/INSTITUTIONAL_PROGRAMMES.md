# Institutional programme foundation

This increment provides tenant-scoped programme setup behind the `institutional.government_dashboard` backend feature flag. Programme records are draft by default and may be created only by organization owners, admins, or programme managers.

Apply `backend/migrations/install_institutional_programme_foundation.sql` through the normal migration runner. To roll back, disable the feature flag, stop new programme writes, export affected rows, and use a reviewed migration after retention and reconciliation checks. Monitoring, cohorts, benefits, outcomes, dashboards, and exports are not claimed complete by this increment.
