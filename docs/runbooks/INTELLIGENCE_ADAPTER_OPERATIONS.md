# Intelligence Mapping and Satellite Operations

## Scope

The intelligence adapter contract exposes tenant-authenticated, provider-neutral mapping resolution and satellite scene metadata inspection. Deterministic adapters are used in tests; no live provider credentials or imagery are assumed.

Satellite responses are metadata-only until a provider is certified. The API must never imply that an unavailable image asset was retrieved.

## Endpoints

- GET /api/intelligence/mapping?latitude=<lat>&longitude=<lon>&at=<iso>
- GET /api/intelligence/satellite?latitude=<lat>&longitude=<lon>&at=<iso>

Both routes require authentication, tenant resolution, and their backend feature flag. Invalid coordinates fail with a 400 response.

## Deployment and monitoring

Enable mapping or satellite per tenant only after provider credentials, quota, provenance, and reconciliation checks are configured. Monitor latency, provider errors, feature decisions, tenant, and correlation ID. Do not log raw tokens or sensitive location metadata beyond the minimum needed for operations.

## Disable and recovery

Disable the affected provider flag to stop new requests while preserving existing evidence. A disabled or degraded provider must return an explicit unavailable result or controlled error; it must not fabricate live imagery or mutate farm records. Restore with a forward-compatible adapter/configuration change, rerun adapter unit tests, API authorization tests, and browser/client checks, then re-enable the tenant flag.

