#!/usr/bin/env bash
#
# Assert that POSTGRES_USER matches the role the dump expects.
#
# The dump carries `ALTER TABLE ... OWNER TO teable;` statements (or whatever
# role it was dumped from), so POSTGRES_USER is a hard requirement rather than
# a naming convention. A mismatch is a FATAL, PARTIAL restore with ON_ERROR_STOP.
#
# This script runs BEFORE the dump (filename sort order) and fails LOUDLY,
# rather than letting the restore half-succeed and the stack come up green
# against a broken database.

set -euo pipefail

EXPECTED_USER="teable"

if [ "${POSTGRES_USER:-}" != "$EXPECTED_USER" ]; then
  cat >&2 <<EOM
FATAL: POSTGRES_USER mismatch.

  expected: $EXPECTED_USER
  got:      ${POSTGRES_USER:-<unset>}

The database dump assigns ownership to '$EXPECTED_USER', so POSTGRES_USER must
match or the restore FAILS PARTWAY with ON_ERROR_STOP.

Fix POSTGRES_USER in .env and restart. Do not change this assertion to match
what you set — a wrong POSTGRES_USER is a half-restored database, not a
working demo with an unexpected username.
EOM
  exit 1
fi

echo "Role assertion passed: POSTGRES_USER=${POSTGRES_USER}"
