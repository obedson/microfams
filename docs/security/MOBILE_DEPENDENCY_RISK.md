# Mobile dependency risk register

Reviewed: 2026-08-09

The mobile application is upgraded to Expo SDK 57 and passes Expo Doctor. At
the time of review, npm still reports high-severity findings through Expo's
build-time Metro toolchain. The registry offers no patched `image-size`
release and incorrectly recommends downgrading Expo as its automated fix.

The accepted findings are restricted in `mobile/scripts/audit-production.mjs`
to the Expo CLI, Metro, React Native CLI integration, and their `image-size`
chain. These packages process trusted repository assets during development and
build; they are not exposed as an application HTTP service. The CI gate fails
for every critical finding and for any high-severity package outside that exact
allowlist.

Required follow-up:

- Re-run `npm audit --omit=dev` on every dependency update.
- Remove each allowlist entry as soon as the Expo-supported dependency chain
  contains a patched release.
- Do not use untrusted images as build inputs while the `image-size` advisory
  remains open.
- Reassess this exception before any production mobile release.
