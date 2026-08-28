#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
setup_file="$repo_root/backend/tests/setup.ts"
fixtures_file="$repo_root/backend/tests/fixtures/tenantFixtures.ts"

test -f "$setup_file"
test -f "$fixtures_file"
grep -q "http://127.0.0.1:54321" "$setup_file"
grep -q "test-service-role-key" "$setup_file"
grep -q "test-jwt-secret-do-not-use-outside-tests" "$setup_file"
test "$(grep -c "organizationId:" "$fixtures_file")" -ge 2
grep -q "Synthetic Cooperative Alpha" "$fixtures_file"
grep -q "Synthetic Cooperative Beta" "$fixtures_file"

if grep -nE "sk_live_|ghp_[A-Za-z0-9]{20,}|-----BEGIN .*PRIVATE KEY-----" "$setup_file" "$fixtures_file"; then
  echo "Live credentials or private keys are not allowed in hermetic test setup." >&2
  exit 1
fi

echo "Hermetic test configuration and synthetic tenant fixtures verified."
