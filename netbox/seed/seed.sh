#!/usr/bin/env bash
#
# Build the NetBox demo estate from nothing and emit the artifact the published
# db image is baked from:
#
#   db/demo.sql.gz
#
# Usage, from the host directory (netbox/):
#
#   FRISIAN_MCP_LOCAL_WHEEL=frisian_mcp-<version>-py3-none-any.whl ./seed/seed.sh
#   FRISIAN_MCP_SPEC='frisian-mcp[usage]==1.1.1'                   ./seed/seed.sh
#
# Exactly one of those two. The Dockerfile refuses a build with neither or both.
#
# ─────────────────────────────────────────────────────────────────────────────
# ONE ARTIFACT, UNLIKE THE PAPERLESS HOST
#
# Paperless splits its estate across both images: the db image carries the SQL
# and the application image carries the document files the SQL points at. A
# NetBox estate is rows only — no media — so there is a single artifact and the
# application image carries none of it.
#
# That also means this seed cannot produce the Paperless failure mode where a
# listing works and every download 404s. There is nothing to get out of step.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_DIR="$(cd "$HERE/.." && pwd)"
cd "$HOST_DIR"

COMPOSE=(docker compose -f docker-compose.yml -f seed/docker-compose.seed.yml)

note() { printf '\n\033[1m── %s\033[0m\n' "$*"; }

# ── Guard: one lane, and it must be stated ──────────────────────────────────
if [ -n "${FRISIAN_MCP_SPEC:-}" ] && [ -n "${FRISIAN_MCP_LOCAL_WHEEL:-}" ]; then
  echo "ERROR: FRISIAN_MCP_SPEC and FRISIAN_MCP_LOCAL_WHEEL are both set. Pick one lane." >&2
  exit 1
fi
if [ -z "${FRISIAN_MCP_SPEC:-}" ] && [ -z "${FRISIAN_MCP_LOCAL_WHEEL:-}" ]; then
  echo "ERROR: no frisian-mcp source selected, and there is no default." >&2
  echo "  PyPI lane:  FRISIAN_MCP_SPEC='frisian-mcp[usage]==1.1.1'" >&2
  echo "  Local lane: FRISIAN_MCP_LOCAL_WHEEL=<file in netbox/wheels/>" >&2
  exit 1
fi
export FRISIAN_MCP_SPEC="${FRISIAN_MCP_SPEC:-}"
export FRISIAN_MCP_LOCAL_WHEEL="${FRISIAN_MCP_LOCAL_WHEEL:-}"

cleanup() {
  note "tearing the seed stack down"
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

MANAGE=(/opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py)

# ── 0. Start from nothing ───────────────────────────────────────────────────
note "clearing the previous artifact"
rm -f "$HOST_DIR/db/demo.sql.gz"
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

# ── 1. Boot a stack with an EMPTY database ──────────────────────────────────
note "booting the seed stack"
#
# `--wait` is deliberately NOT used here.
#
# The NetBox container restarts once during first boot — the entrypoint runs
# migrations, exits, and `restart: unless-stopped` brings it back. `--wait`
# treats that single restart as a failure and reports "container ... is
# unhealthy" while the stack is in fact fine: left alone it reaches healthy in
# about two and a half minutes.
#
# So poll the container's own health status instead, which tolerates a restart
# and fails on a timeout rather than on a transient.
"${COMPOSE[@]}" up -d --build

printf '  waiting for netbox to become healthy'
deadline=$(( SECONDS + 1200 ))
while :; do
  state=$(docker inspect --format '{{.State.Health.Status}}' \
            "$("${COMPOSE[@]}" ps -q netbox 2>/dev/null)" 2>/dev/null || echo starting)
  [ "$state" = "healthy" ] && { printf ' healthy\n'; break; }
  if [ "$SECONDS" -ge "$deadline" ]; then
    printf '\n'
    echo "ERROR: netbox did not become healthy within 20 minutes (last state: $state)." >&2
    "${COMPOSE[@]}" logs --no-color --tail 60 netbox >&2 || true
    exit 1
  fi
  printf '.'
  sleep 10
done

# ── 1b. Complete the schema ─────────────────────────────────────────────────
#
# The plugin wrapper adds `django.contrib.admin` to INSTALLED_APPS so
# frisian-mcp's OAuth admin views resolve. NetBox does not ship that app, so
# nothing has ever created `django_admin_log` — and deleting a user CASCADES
# into it, which is how this surfaced:
#
#     django.db.utils.ProgrammingError: relation "django_admin_log" does not exist
#
# ...raised while removing the build-only identity, several steps after the
# app that needs the table was added.
#
# `migrate` is idempotent and cheap here; running it makes the schema match
# INSTALLED_APPS rather than assuming the image's own boot migration covered an
# app the image does not know about.
note "completing the schema for plugin-added apps"
"${COMPOSE[@]}" exec -T netbox "${MANAGE[@]}" migrate --no-input 2>&1 | tail -3

# ⚠️ `migrate` is NOT sufficient for django.contrib.admin here, and the reason
# is worth writing down.
#
# Measured on NetBox 4.6.2: `django.contrib.admin` IS in INSTALLED_APPS (the
# wrapper adds it), `migrate` reports "No migrations to apply" — and
# `django_admin_log` still does not exist. Its migrations are recorded as
# APPLIED without the table ever having been created, so a plain migrate is a
# no-op and the schema stays incomplete.
#
# Marking them unapplied and re-running is what actually builds the table.
# Guarded so it only fires when the table really is missing, because
# `migrate admin zero` is destructive on a host where the table exists.
if ! "${COMPOSE[@]}" exec -T netbox "${MANAGE[@]}" shell -c \
      "from django.db import connection; import sys; sys.exit(0 if 'django_admin_log' in connection.introspection.table_names() else 1)" \
      >/dev/null 2>&1; then
  note "creating django_admin_log (recorded as migrated, never created)"
  "${COMPOSE[@]}" exec -T netbox "${MANAGE[@]}" migrate admin zero --fake --no-input >/dev/null 2>&1
  "${COMPOSE[@]}" exec -T netbox "${MANAGE[@]}" migrate admin --no-input 2>&1 | tail -2
fi

# ── 2. Provision identities, including the build-only one ───────────────────
#
# The builder is scoped rather than superuser on purpose: a superuser cannot be
# refused, so it would silently paper over a missing capability that this run
# exists to exercise.
note "provisioning identities (with the build-only identity)"
"${COMPOSE[@]}" exec -T -e DEMO_PROVISION_BUILDER=1 netbox \
  "${MANAGE[@]}" shell < db/provision_identities.py

# ── 3. Build the estate ─────────────────────────────────────────────────────
note "building the estate"
"${COMPOSE[@]}" exec -T netbox "${MANAGE[@]}" shell < seed/build_estate.py

# ── 4. Remove the build-only identity ───────────────────────────────────────
#
# Re-running the provisioner WITHOUT the flag is what deletes it — the script
# is declarative, so "absent" is a state it enforces rather than something this
# script has to know how to undo.
note "removing the build-only identity"
"${COMPOSE[@]}" exec -T netbox "${MANAGE[@]}" shell < db/provision_identities.py

# ── 5. Harvest the artifact ─────────────────────────────────────────────────
#
# Dumped from INSIDE the db container, so pg_dump and the server are the same
# version by construction. A newer client emits GUCs an older server rejects in
# the dump preamble, and the postgres entrypoint restores with ON_ERROR_STOP —
# so that mismatch is a fatal, partial restore rather than a warning.
note "dumping the database"
"${COMPOSE[@]}" exec -T db \
  pg_dump -U "${POSTGRES_USER:-netbox}" -d "${POSTGRES_DB:-netbox}" \
  | gzip -9 > "$HOST_DIR/db/demo.sql.gz"
gzip -t "$HOST_DIR/db/demo.sql.gz"

size=$(wc -c < "$HOST_DIR/db/demo.sql.gz" | tr -d ' ')
cat <<EOS

── seeded ───────────────────────────────────────────
  db/demo.sql.gz    ${size} bytes

Next:
  docker compose -f docker-compose.yml -f docker-compose.build.yml up --build
EOS
