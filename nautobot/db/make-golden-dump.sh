#!/usr/bin/env bash
#
# B5 — produce the golden SQL artifact.
#
# THE STRIP AND THE DUMP ARE ONE STEP. That ordering is the requirement, not
# the deletion itself. django_session.session_key IS the session cookie in
# plaintext; sessions accumulate continuously, so a strip that runs at any
# other time is decoration — anyone who logs in between a standalone clear and
# the dump puts a working superuser cookie back into the artifact.
#
# Run against the live demo stack's db container. Produces nautobot/db/demo.sql.gz.
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-frisian-mcp-demo-nautobot-db-1}"
OUT="${OUT:-$(cd "$(dirname "$0")" && pwd)/demo.sql.gz}"

echo "== pre-strip counts =="
docker exec "$DB_CONTAINER" psql -U nautobot -d nautobot -qtAX -c "
  SELECT 'django_session='||count(*) FROM django_session
  UNION ALL SELECT 'django_admin_log='||count(*) FROM django_admin_log
  UNION ALL SELECT 'extras_objectchange='||count(*) FROM extras_objectchange;"

echo "== STRIP + DUMP (single step) =="
# One psql invocation, one transaction, then pg_dump immediately after with no
# opportunity for a login to land in between.
docker exec "$DB_CONTAINER" psql -U nautobot -d nautobot -v ON_ERROR_STOP=1 -qX -c "
  BEGIN;
  DELETE FROM django_session;
  DELETE FROM django_admin_log;
  DELETE FROM extras_objectchange;
  COMMIT;"

# Faithful dump: ownership deliberately RETAINED. db/00-assert-role.sh and the
# db Dockerfile both depend on the ALTER TABLE ... OWNER TO nautobot statements
# being present — that is what makes POSTGRES_USER an enforceable requirement
# rather than a convention.
docker exec "$DB_CONTAINER" pg_dump -U nautobot -d nautobot | gzip -9 > "$OUT"

echo "== artifact =="
ls -l "$OUT"
gzip -t "$OUT" && echo "gzip -t OK"
shasum -a 256 "$OUT"

echo "== post-strip verification (source db) =="
docker exec "$DB_CONTAINER" psql -U nautobot -d nautobot -qtAX -c "
  SELECT 'django_session='||count(*) FROM django_session
  UNION ALL SELECT 'django_admin_log='||count(*) FROM django_admin_log
  UNION ALL SELECT 'extras_objectchange='||count(*) FROM extras_objectchange;"
