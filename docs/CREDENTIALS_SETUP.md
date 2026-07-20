# Credentials and Integration Setup

## Important

This document lists secret names only. Never place credential values in this file, an issue, a PR, chat, source code, or a committed environment file.

Provide values once through GitHub Codespaces secrets for development and the deployment platform's environment-scoped secret manager for staging/production. Use separate sandbox and live credentials. Rotate any value previously committed to Git history.

## Core platform

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `DATABASE_URL` (pooled application connection)
- `DATABASE_DIRECT_URL` (migrations and administrative jobs)
- `REDIS_URL`
- `JWT_SECRET`
- `JWT_REFRESH_SECRET`
- `FIELD_ENCRYPTION_KEY`
- `WEBHOOK_ENCRYPTION_KEY`
- `APP_BASE_URL`
- `API_BASE_URL`

## Paystack

Sandbox and live:

- `PAYSTACK_PUBLIC_KEY`
- `PAYSTACK_SECRET_KEY`
- `PAYSTACK_WEBHOOK_SECRET` if issued/configured
- merchant/business identifier and settlement account configured in the Paystack dashboard

## Interswitch

Sandbox and live, for enabled products:

- `INTERSWITCH_BASE_URL`
- `INTERSWITCH_AUTH_URL`
- `INTERSWITCH_MARKETPLACE_URL`
- `INTERSWITCH_CLIENT_ID`
- `INTERSWITCH_CLIENT_SECRET`
- `INTERSWITCH_TERMINAL_ID`
- `INTERSWITCH_WEBHOOK_SECRET`
- `INTERSWITCH_TRANSFER_FEE_KOBO`
- merchant/settlement identifiers required for Virtual NUBAN, name enquiry, transfers, NIN/BVN, and transaction search

## Identity and government verification

Provider selection is still required for any capability not covered by Interswitch:

- NIN verification sandbox/live credentials and approved product scope
- BVN verification credentials
- phone ownership/OTP credentials
- face/liveness verification credentials
- organization/CAC verification credentials
- any government programme API client IDs, secrets, signing certificates, or allowlisted IP information

Organization verification also requires:

- `ORGANIZATION_REGISTRATION_FINGERPRINT_KEY`
- `ORGANIZATION_VERIFICATION_PROVIDER`
- the selected provider environment, endpoint, client identifier, secret or certificate, and webhook/signature settings

## Email, SMS, and push

Current email:

- `BREVO_API_KEY`
- `FROM_EMAIL`
- `FROM_NAME`

Select an SMS/OTP provider (Termii, Africa's Talking, Twilio, or another approved vendor), then supply:

- `SMS_PROVIDER`
- `SMS_API_KEY`
- `SMS_API_SECRET` if applicable
- `SMS_SENDER_ID`
- provider template/application identifiers

Mobile/push:

- `EXPO_ACCESS_TOKEN`
- `EXPO_PROJECT_ID`
- Firebase service-account credential or FCM server credential
- Apple APNs key ID, team ID, and private signing key when iOS delivery is required

## Storage and media

AWS S3:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `AWS_S3_BUCKET`
- `AWS_S3_PUBLIC_BASE_URL` or CDN URL

If Cloudinary remains enabled:

- `CLOUDINARY_CLOUD_NAME`
- `CLOUDINARY_API_KEY`
- `CLOUDINARY_API_SECRET`

## Maps, weather, and satellite

Select providers before integration approval.

Maps/geocoding, choose one or more:

- Google Maps API key and restricted application identifiers
- Mapbox access token

Weather, choose one:

- Tomorrow.io API key
- OpenWeather API key
- WeatherAPI key or approved alternative

Satellite/remote sensing, choose one:

- Sentinel Hub OAuth client ID and secret
- Planet API key
- Google Earth Engine service-account credentials and project ID
- approved local or government geospatial provider credentials

Also provide any required AOI limits, imagery licensing terms, and permitted storage/cache duration.

## AI

Select the permitted model providers and data-processing policy:

- `OPENAI_API_KEY` and approved model IDs
- optional alternative provider keys
- embedding/vector-store credentials if externally hosted
- moderation/safety provider configuration
- per-tenant budget and model allowlists

AI credentials must not grant direct database access. The assistant uses authorized application services.

## Monitoring and operations

- `SENTRY_DSN`
- `SENTRY_AUTH_TOKEN` for releases if used
- log/metrics provider token
- uptime/incident provider token
- backup storage credentials
- deployment provider tokens only where automated deployment requires them

## Financial-product providers

Provider selections and commercial agreements are needed for live operation:

- bank/virtual-account and transfer credentials;
- escrow/custody or trustee credentials;
- credit bureau credentials (for example CRC Credit Bureau or FirstCentral, if selected);
- loan disbursement and direct-debit/mandate credentials;
- investment/custody/valuation provider credentials;
- identity, AML, sanctions, or transaction-monitoring provider credentials.

The internal workflows and adapters can be completed before every provider is selected, but a live feature flag must validate that the required provider configuration exists.

## Tenant enterprise access

If institutional SSO is required:

- OAuth/OIDC client ID and secret per provider;
- SAML metadata, entity ID, certificate, and callback URLs;
- government/NGO API credentials and signing keys;
- tenant-specific webhook secrets.

## What to provide now

Create sandbox/test credentials first for Supabase, Paystack, Interswitch products already approved, Brevo, S3, SMS/OTP, and the selected maps/weather/satellite/AI providers. Add each value as a GitHub Codespaces secret using the exact name above. Do not send the secret values in chat.

Live credentials should be added only to protected staging/production secret stores and enabled through audited backend feature flags.
