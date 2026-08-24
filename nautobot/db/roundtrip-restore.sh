#!/usr/bin/env bash
#
# B5 round-trip step 1 — restore the golden artifact through the REAL first-boot
# path and time it.
#
# Times the whole first-boot restore, not a bare `psql -f`, because that is the
# figure users actually experience: `pgdata` was dropped, so this runs on EVERY
# boot, not just the first.
#
# Mounts exactly what db/Dockerfile bakes: 00-assert-role.sh then demo.sql.gz,
# in filename order, into /docker-entrypoint-initdb.d/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${NAME:-b5_roundtrip}"
PORT="${PORT:-55433}"

docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "== starting fresh postgres:17 with the baked initdb.d layout =="
START=$(python3 -c 'import time; print(time.time())')

docker run -d --name "$NAME" \
  -e POSTGRES_USER=nautobot \
  -e POSTGRES_PASSWORD=roundtrip \
  -e POSTGRES_DB=nautobot \
  -p "${PORT}:5432" \
  -v "${HERE}/00-assert-role.sh:/docker-entrypoint-initdb.d/00-assert-role.sh:ro" \
  -v "${HERE}/demo.sql.gz:/docker-entrypoint-initdb.d/demo.sql.gz:ro" \
  postgres:17 >/dev/null

# Wait until the REAL server (post-init) is serving. The entrypoint runs init
# scripts against a temporary local-only server first, so a successful TCP query
# on the published port means init has finished and the restore is complete.
for i in $(seq 1 600); do
  if docker exec "$NAME" pg_isready -U nautobot -d nautobot -h 127.0.0.1 >/dev/null 2>&1 \
     && docker exec "$NAME" psql -U nautobot -d nautobot -qtAX -c 'SELECT 1' >/dev/null 2>&1; then
    # Confirm the restore actually landed, not just that postgres is up.
    if [ "$(docker exec "$NAME" psql -U nautobot -d nautobot -qtAX -c 'SELECT count(*) FROM dcim_device' 2>/dev/null || echo 0)" -gt 0 ]; then
      break
    fi
  fi
  sleep 0.5
done

END=$(python3 -c 'import time; print(time.time())')
ELAPSED=$(python3 -c "print(f'{${END} - ${START}:.1f}')")

echo
echo "=================================================="
echo "  RESTORE TIME (container start -> serving): ${ELAPSED}s"
echo "=================================================="
echo

echo "== role assertion fired? =="
docker logs "$NAME" 2>&1 | grep -m1 '00-assert-role' || echo "  (assertion line not found)"

echo "== restored estate =="
docker exec "$NAME" psql -U nautobot -d nautobot -qtAX -c "
  SELECT relname||'='||n_live_tup FROM pg_stat_user_tables
  WHERE relname IN ('dcim_device','dcim_interface','dcim_cable','dcim_location',
                    'dcim_rack','ipam_prefix','ipam_vlan','ipam_ipaddress',
                    'ipam_ipaddresstointerface','circuits_circuit',
                    'nautobot_bgp_models_peering','nautobot_golden_config_compliancerule',
                    'auth_user','frisian_mcp_tokens_frisianmcptoken',
                    'frisian_mcp_oauth_oauthclient','users_objectpermission')
  ORDER BY relname;"

echo "== stripped tables (must all be 0) =="
docker exec "$NAME" psql -U nautobot -d nautobot -qtAX -c "
  SELECT 'django_session='||count(*) FROM django_session
  UNION ALL SELECT 'django_admin_log='||count(*) FROM django_admin_log
  UNION ALL SELECT 'extras_objectchange='||count(*) FROM extras_objectchange;"

echo "== tables =="
docker exec "$NAME" psql -U nautobot -d nautobot -qtAX -c \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"

echo
echo "Container '${NAME}' left running on port ${PORT} for the assertion and acceptance run."
