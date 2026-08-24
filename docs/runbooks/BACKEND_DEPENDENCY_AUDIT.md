# Dependency Audit and Exceptions

The backend development toolchain now uses `tsx` 4.23.12, which resolves the patched `esbuild` 0.28.x line. The backend and frontend production-only audits report zero vulnerabilities.

CI also audits the root workspace and `mcp-servers` dependency trees. The mobile job uses `mobile/scripts/audit-production.mjs`: it fails on critical findings and any unapproved high finding. The currently accepted high findings are transitive Expo/Metro build-toolchain packages (`@expo/metro`, `image-size`, `metro`, `metro-config`, and `metro-transform-worker`). They cannot be remediated independently without a breaking Expo downgrade; they are not runtime application dependencies. Revisit this exception whenever the Expo SDK is upgraded.
