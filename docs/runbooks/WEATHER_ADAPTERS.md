# Weather Adapters

Weather access is tenant-scoped and protected by the `integration.weather` backend feature flag. Providers must implement the shared adapter contract; the deterministic adapter is for tests and controlled development only.

Every response records provider, observation time, coordinates, condition, and confidence. Do not present deterministic or stale data as a live forecast. Disable the flag when provider credentials, freshness, jurisdiction, or reliability checks fail; existing farm records remain unchanged.
