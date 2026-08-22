#!/usr/bin/env bash
#
# B3 — provision the frisian-mcp demo identities.
#
# Thin wrapper so CI has one stable entry point. All logic lives in
# provision_identities.py, which is idempotent and re-runnable.
#
# Usage (inside or against the app container):
#   ./nautobot/db/provision.sh                       # the three demo identities
#   DEMO_PROVISION_BUILDER=1 ./nautobot/db/provision.sh   # + the B4 build-only identity
#
# The build-only identity is opt-in and MUST NOT survive to the golden dump.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/provision_identities.py"

[ -f "$script" ] || { echo "::error::${script} not found."; exit 1; }

# NAUTOBOT_CONTAINER lets CI target a running compose service; unset means we
# are already inside the container.
if [ -n "${NAUTOBOT_CONTAINER:-}" ]; then
  docker exec -i \
    -e DEMO_PROVISION_BUILDER="${DEMO_PROVISION_BUILDER:-}" \
    "$NAUTOBOT_CONTAINER" nautobot-server shell < "$script"
else
  nautobot-server shell < "$script"
fi
