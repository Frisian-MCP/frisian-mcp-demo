#!/bin/bash
# Runs before the demo dump restores. Sorts ahead of demo.sql.gz on purpose —
# the postgres entrypoint executes /docker-entrypoint-initdb.d/ in filename
# order, so "00-" gets there first.
#
# WHY THIS EXISTS
#
# The golden dump assigns table ownership to the `netbox` role. The postgres
# entrypoint restores .sql.gz with ON_ERROR_STOP, so a role that does not match
# makes the restore FATAL rather than merely noisy — and the stack then comes
# up with a database that is empty or half-populated, for a reason buried
# hundreds of lines into a container log.
#
# POSTGRES_USER matching the dump's role is therefore a hard requirement, not a
# naming convention. It looks like a convention, which is exactly why it needs
# an assertion: `POSTGRES_USER=postgres` is an entirely reasonable-looking edit.
#
# This is also the enforcement point for the compose file's
# ${POSTGRES_USER:-netbox}. Compose cannot assert its own values, so the check
# lives here, where every path into this image passes through it.
set -euo pipefail

EXPECTED_ROLE="netbox"

if [ "${POSTGRES_USER:-}" != "$EXPECTED_ROLE" ]; then
  echo "============================================================" >&2
  echo "FATAL: POSTGRES_USER is '${POSTGRES_USER:-<unset>}', expected '${EXPECTED_ROLE}'." >&2
  echo >&2
  echo "The baked demo dump assigns ownership to the '${EXPECTED_ROLE}' role."  >&2
  echo "Restoring under a different role fails partway through and leaves an"   >&2
  echo "incomplete database. Stopping now instead, while the reason is still"   >&2
  echo "the first thing in the log."                                            >&2
  echo >&2
  echo "Set POSTGRES_USER=${EXPECTED_ROLE} (and DB_USER to match)."             >&2
  echo "============================================================" >&2
  exit 1
fi

echo "[00-assert-role] POSTGRES_USER=${POSTGRES_USER} — matches the baked dump."
