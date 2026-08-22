## Request correlation and health checks

Every request receives a validated `x-correlation-id` response header. A valid UUID supplied by an upstream gateway is preserved; malformed values are replaced with a generated UUID. Operators should include this ID when correlating API responses, logs, job attempts, and provider incidents. `GET /health` returns the same correlation ID and confirms the process is serving requests; dependency readiness remains a separate deployment check.# Deployment Configuration

## Browser API routing

Set the Vercel `REACT_APP_API_URL` value to the backend API base URL with no surrounding whitespace:

```text
https://micro-farmle.onrender.com/api
```

The frontend trims this value defensively, but deployment values must still be reviewed before promotion.

## Browser origins

The backend accepts browser requests from:

- local development on ports 3000 and 3001;
- `https://microfams.vercel.app`;
- the project-specific `microfams-git-*-obedsons-projects.vercel.app` preview hostname pattern;
- additional exact HTTP(S) origins listed in the comma-separated `CORS_ALLOWED_ORIGINS` variable.

Do not add broad `*.vercel.app` or reflected-origin policies. Add another exact origin through deployment configuration when a new frontend environment is introduced.

## Verification

1. Confirm `GET /health` returns HTTP 200.
2. Send an OPTIONS request to `/api/auth/register` with the target frontend in the `Origin` header.
3. Confirm `access-control-allow-origin` exactly matches that origin.
4. Submit a disposable registration and confirm navigation to `/dashboard`.
