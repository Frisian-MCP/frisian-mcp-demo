"""
Provision the frisian-mcp demo identities for Teable (Nest host).

This is a PLACEHOLDER for Phase 7 tip work. Teable uses JWT / API tokens
rather than Django tokens, and identity provisioning will differ from the
Python hosts.

Run inside the application container once the provisioning mechanism is
designed:

    # Method TBD — depends on Teable's user/token model
    docker compose exec teable node /path/to/provision-script.js

OR

    docker compose exec teable some-teable-cli provision-users

Idempotent — safe to re-run. CI re-runs it; a wipe drops the database, so it
MUST be re-run against any freshly initialised instance.

WHAT THIS DEMONSTRATES
----------------------
The same server showing a different `tools/list` to different agents. Three
identities, three doors, three tier ceilings:

    demo-readonly   read        mcp/read-only    view on the scoped estate
    demo-user       read_write  mcp/read-write   view + write on allowed resources
    demo-admin      admin       mcp/ops          superuser / full access

TOKENS ARE FIXED, PUBLISHED CONSTANTS
-------------------------------------
Frisian tokens for Nest hosts use the same HMAC-SHA256(raw, key) scheme as
Python hosts. The key is FRISIAN_MCP_HMAC_KEY. Tokens are published by design;
nothing here is a secret.

If FRISIAN_MCP_HMAC_KEY is not the demo constant when this runs, every token
minted here is unverifiable in the shipped image, silently. The script refuses
to run in that case rather than producing dead tokens.

NEST HOST IDENTITY PROVISIONING NOTES (Phase 7)
-----------------------------------------------
- Teable likely provisions users via its own API or admin interface
- Token format may differ from Django (JWT vs Bearer)
- OAuth client provisioning (if supported) follows Teable's patterns
- Scoping mechanism depends on Teable's RBAC/permission model

GOLDEN SQL DUMP REQUIREMENT
---------------------------
Once identities are provisioned and the estate is seeded, produce demo.sql.gz:

    docker compose exec db pg_dump -U teable -d teable | gzip > db/demo.sql.gz

This dump becomes the golden artifact injected by CI into db/Dockerfile.
"""

import sys

# Placeholder — implement when Teable identity model is known
def main():
    print("Teable identity provisioning placeholder (Phase 7)")
    print("")
    print("This script is a contract placeholder. Implement when:")
    print("  1. Teable's user/token API is documented")
    print("  2. Frisian Nest MCP door configuration is finalized")
    print("  3. Golden SQL dump path is established")
    print("")
    print("Expected identities:")
    print("  demo-readonly   (read door)")
    print("  demo-user       (read-write door)")
    print("  demo-admin      (ops/admin door)")
    print("")
    print("Tokens (published constants):")
    print("  frisian-demo-readonly-token-public-do-not-reuse")
    print("  frisian-demo-user-token-public-do-not-reuse")
    print("  frisian-demo-admin-token-public-do-not-reuse")
    print("")
    print("See common/docs/HOST-CONTRACT.md Nest section.")
    
    # Exit 0 for now — provisioning is manual until the mechanism is designed
    return 0

if __name__ == "__main__":
    sys.exit(main())
