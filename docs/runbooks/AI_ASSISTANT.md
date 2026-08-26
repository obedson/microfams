# AI assistant contract
The assistant endpoint is tenant-scoped and backend-gated by integration.ai_assistant. The current adapter is deterministic and returns citations supplied by approved service callers; it performs no mutations. Any future action-capable provider must require explicit human confirmation, audit the request, and use typed domain services. Disable the flag to stop new requests.
