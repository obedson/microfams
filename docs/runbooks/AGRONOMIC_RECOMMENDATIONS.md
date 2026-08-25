# Agronomic Recommendations

Recommendations are generated from tenant-scoped farm records by deterministic rules. Each result includes a rule ID, confidence score, source record IDs, and generation timestamp. They are advisory evidence, not a diagnosis or guaranteed yield outcome.

## Controls

The endpoint `/api/farm-records/recommendations` requires the tenant context and `intelligence.agronomic_recommendations` backend feature flag. The flag is disabled by default until the organization has approved the workflow and data policy.

When disabled, the API returns `FEATURE_DISABLED`; existing farm records remain available. Re-enable only after checking tenant permissions, source-data quality, rule changes, and support ownership.

## Review and recovery

Operators must retain the returned rule ID, provenance, confidence, tenant, and timestamp with any downstream case or support report. Investigate unexpected output by checking the source record IDs and deterministic rule version. Never edit farm records to force a recommendation; correct source data through the normal farm-record workflow and regenerate.
