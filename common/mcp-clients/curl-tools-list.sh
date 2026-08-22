#!/usr/bin/env sh
set -eu

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ROUTE="${ROUTE:-mcp/read-only}"

if [ -z "${TOKEN:-}" ]; then
  echo "Set TOKEN to one of the published demo bearer tokens." >&2
  exit 2
fi

curl -sS \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  "${BASE_URL%/}/${ROUTE#/}/"
