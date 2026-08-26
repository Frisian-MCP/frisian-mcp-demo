#!/usr/bin/env sh
# Ask one dispatcher what actions it will expose to this identity.
#
# This is the instrument that shows permission-aware discovery. `tools/list` on
# a scoped door returns the same 12 group dispatchers for every caller, because
# the group list belongs to the route. The per-identity difference is in each
# dispatcher's action list, which is what `action: "help"` returns.
#
#   TOKEN=<bearer> ROUTE=mcp/read-write ./curl-help.sh dcim
#
# Compare two runs that differ in exactly one variable — the identity, or the
# group — and the differing action lists are the demonstration.
set -eu

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ROUTE="${ROUTE:-mcp/read-only}"
GROUP="${1:-}"

if [ -z "${TOKEN:-}" ]; then
  echo "Set TOKEN to one of the published demo bearer tokens." >&2
  exit 2
fi

if [ -z "$GROUP" ]; then
  echo "Usage: TOKEN=<token> [BASE_URL=...] [ROUTE=mcp/read-only] $0 <group>" >&2
  echo >&2
  echo "Nautobot  (BASE_URL=http://127.0.0.1:8080, the default):" >&2
  echo "  dcim ipam circuits tenancy virtualization wireless cloud" >&2
  echo "  golden_config dns bgp ssot extras" >&2
  echo >&2
  echo "Paperless (BASE_URL=http://127.0.0.1:8081):" >&2
  echo "  documents classification mail workflow monitoring" >&2
  echo "  sharing system            (admin door only)" >&2
  exit 2
fi

curl -sS \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"${GROUP}\",\"arguments\":{\"action\":\"help\"}}}" \
  "${BASE_URL%/}/${ROUTE#/}/"
