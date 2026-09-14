#!/usr/bin/env bash
#
# Assert that the demo identities roster exists and matches expectations.
#
# This runs INDEPENDENTLY of provision_identities.py: it is defence in depth,
# not a check that provisioning succeeded. If provisioning silently omits a
# door or mints a token under the wrong key, this script is the thing that
# says so.
#
# CONTRACT: invoked from anywhere, exits 0 if the roster is correct.

set -euo pipefail

# NOTE: This is a PLACEHOLDER for Phase 7 Teable work.
#
# The real assertion will query Teable's user/token tables (or API) and verify:
#   1. demo-readonly, demo-user, demo-admin users exist
#   2. Their tokens match the published constants
#   3. Token HMAC validates under FRISIAN_MCP_HMAC_KEY
#   4. OAuth client (if applicable) exists and is correctly configured
#
# For now, emit a clear notice that this check is deferred.

cat <<'EOM'
──────────────────────────────────────────────────────────────────────────────
Teable identity assertion (PLACEHOLDER - Phase 7)

This check is deferred until Teable's identity provisioning mechanism is
implemented. A real assertion will verify:

  ✓ demo-readonly user exists, token verifiable
  ✓ demo-user user exists, token verifiable  
  ✓ demo-admin user exists, token verifiable
  ✓ Tokens HMAC under FRISIAN_MCP_HMAC_KEY=frisian-mcp-demo-public-hmac-key-do-not-reuse
  ✓ OAuth client (if applicable) configured with published client_id/secret

CURRENT STATUS: skipped (no golden dump yet, no provisioner)

See db/provision_identities.py and common/docs/HOST-CONTRACT.md Nest section.
──────────────────────────────────────────────────────────────────────────────
EOM

# Exit 0 for now — this becomes exit 1 if assertions fail once implemented
exit 0
