#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <postgres-connection-url>" >&2
  exit 64
fi

connection_url="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
migration_dir="$(cd -- "$script_dir/../migrations" && pwd)"
manifest="$migration_dir/schema-manifest.txt"

while IFS= read -r migration || [[ -n "$migration" ]]; do
  [[ -z "$migration" || "$migration" == \#* ]] && continue
  path="$migration_dir/$migration"
  if [[ ! -f "$path" ]]; then
    echo "manifest references missing migration: $migration" >&2
    exit 66
  fi
  echo "applying $migration"
  psql "$connection_url" --set ON_ERROR_STOP=1 --file "$path" >/dev/null
done < "$manifest"

echo "schema migrations applied successfully"
