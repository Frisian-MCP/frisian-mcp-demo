#!/usr/bin/env bash
#
# Acceptance checklist for the NetBox demo host.
#
# CONTRACT
# --------
# Invoked from anywhere, with no arguments and no required environment, after
# the true zero-flag boot:
#
#     cd netbox && docker compose up -d
#     ./common/ci/acceptance-netbox.sh
#
# There is deliberately no flag, no profile and no -f chain that makes this
# pass. If acceptance needed one, the demo would be broken for every user
# regardless of whether CI was green — so the script is written to fail in that
# case rather than to accommodate it.
#
# NOTE: `up -d` WITHOUT `--wait`. The netbox container restarts itself once
# during first boot while it waits for the database, and `--wait` treats that
# restart as a failed start rather than as part of starting.
#
# WHY IT PARSES OUTPUT INSTEAD OF TRUSTING EXIT CODES
# ---------------------------------------------------
# Measured on the Nautobot host: `check` exits 0 while emitting a frisian_mcp
# warning. A check that only tested `$?` would report a clean system check on a
# config with a live warning. Every Django-level check below therefore inspects
# stdout as well as the exit code.
#
# WHAT THIS HOST IS FOR, AND WHY SECTION 5 IS THE POINT
# -----------------------------------------------------
# NetBox is the demo host that carries three doors rather than one, so it is
# the only one where the ROUTE CEILING can be demonstrated separately from
# per-user permissions. Section 5 sends ONE token — the admin one — at two
# doors and requires the answers to differ. Nothing else in this file catches a
# wrapper that mounts three URLs onto the same unfiltered view: such a build
# passes reachability, passes auth, passes every read, and serves the full
# write surface on the read-only door. It shipped once. Section 5 is why it
# will not ship again.
#
# WHY IT LEAVES NO RESIDUE
# ------------------------
# The write proof edits an existing site's description and puts it back, rather
# than creating an object. `demo-netops` holds add and change and NOT delete,
# so an object it creates cannot be removed by the identity that created it — a
# create-based proof would need the admin token to clean up, or would leak an
# object into the estate.
#
# It does leave ObjectChange rows, which is unavoidable for a real write. Those
# are the SCRIPT's writes, not the artifact's: `db/assert-identities.sh`
# asserts the change log is empty and must therefore run against a freshly
# booted stack, not after this. `docker compose restart` resets it.
#
# BASH 3.2 COMPATIBLE on purpose (no associative arrays, no mapfile): CI runs
# ubuntu but this has to be runnable on a maintainer's macOS box.
set -uo pipefail

# ── Locate the repo and the compose project ────────────────────────────────
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
COMPOSE_DIR="$REPO_ROOT/netbox"

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  echo "::error::cannot find netbox/docker-compose.yml from $REPO_ROOT" >&2
  exit 2
fi

# Honour the committed .env so the script follows the port the user actually
# booted on, rather than assuming the default and reporting a false failure.
DEMO_BIND_HOST=127.0.0.1
DEMO_HTTP_PORT=8083
if [ -f "$COMPOSE_DIR/.env" ]; then
  v=$(grep -E '^DEMO_BIND_HOST=' "$COMPOSE_DIR/.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')
  [ -n "${v:-}" ] && DEMO_BIND_HOST="$v"
  v=$(grep -E '^DEMO_HTTP_PORT=' "$COMPOSE_DIR/.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')
  [ -n "${v:-}" ] && DEMO_HTTP_PORT="$v"
fi
# 0.0.0.0 is a bind address, not a destination.
[ "$DEMO_BIND_HOST" = "0.0.0.0" ] && DEMO_BIND_HOST=127.0.0.1
BASE_URL="http://${DEMO_BIND_HOST}:${DEMO_HTTP_PORT}"

# ── The three doors ────────────────────────────────────────────────────────
# Must match FRISIAN_MCP_ROUTES in netbox/config/frisian_mcp.py.
#
# The admin door is `ops`, not `admin`: MCP clients strip an `admin` suffix and
# retry the bare URL, landing the caller on a different route with a different
# ceiling, silently. Do not tidy the path.
DOOR_RO="api/mcp/read-only"
DOOR_RW="api/mcp/read-write"
DOOR_OPS="api/mcp/ops"

# ── Published demo credentials ─────────────────────────────────────────────
# Fixed constants provisioned by netbox/db/provision_identities.py and
# documented in netbox/README.md. Published by design; nothing here is a
# secret. If these stop matching the provisioner, MCP auth fails and this
# script is the thing that says so.
TOK_RO="frisian-demo-readonly-token-public-do-not-reuse"
TOK_NO="frisian-demo-netops-token-public-do-not-reuse"
TOK_ADM="frisian-demo-admin-token-public-do-not-reuse"
DEMO_PASSWORD="frisian-demo-public-password"

fail=0
checks=0
note() { printf '  %s\n' "$*"; }
ok()   { checks=$((checks+1)); printf '  ok    %s\n' "$*"; }
bad()  { checks=$((checks+1)); fail=1; printf '  FAIL: %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }

dc() { ( cd "$COMPOSE_DIR" && docker compose "$@" ); }
nmanage() { dc exec -T netbox /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py "$@"; }

# JSON-RPC tools/call against a door. $1 token, $2 door, $3 group,
# $4 resource, $5 action, $6 params-object
mcp() {
  curl -sS --max-time 120 -X POST \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":{\"resource\":\"$4\",\"action\":\"$5\",\"params\":$6}}}" \
    "${BASE_URL}/$2/"
}
# `help` on one resource — the instrument that shows both the route ceiling and
# permission-aware discovery, because the difference lives in the ACTION list
# rather than in the group list. Two doors offering the same groups can still
# offer completely different actions, and that distinction is the whole demo.
mcp_help() {
  curl -sS --max-time 120 -X POST \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":{\"resource\":\"$4\",\"action\":\"help\"}}}" \
    "${BASE_URL}/$2/"
}
mcp_list_tools() {
  curl -sS --max-time 120 -X POST \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
    "${BASE_URL}/$2/"
}
http_code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 60 "$@"; }
door_code() {  # $1 token (may be empty), $2 door
  if [ -n "$1" ]; then
    curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
      -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "${BASE_URL}/$2/"
  else
    curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "${BASE_URL}/$2/"
  fi
}

# The dispatcher returns its payload as an escaped JSON string inside
# result.content[].text, so values are pulled with a tolerant matcher rather
# than by decoding two layers of JSON without a parser dependency.
#
# `grep -o | head -1` and NOT `sed 's/.*KEY.*/'`: `.*` is greedy, so the sed
# form silently returns the LAST match in the payload rather than the first.
# TWO envelope shapes, one extractor.
#
# A small list comes back as   \"count\": 8
# A list over the heavy-response size threshold comes back as a PREVIEW plus a
# continuation token, where the same field is nested one layer deeper and
# quoted as a string:          \\\"count\\\": \\\"8\\\"
#
# The 8-device list on this estate crosses that threshold (total_size ~15.8kB)
# while the 4-device filtered list does not — so a naive extractor passes the
# filtered check and returns nothing for the unfiltered one, which reads as a
# broken estate rather than as a working feature.
#
# Stripping backslashes first collapses both shapes to `"count": 8` or
# `"count": "8"`, and the optional quote in the pattern covers the rest.
extract_count() {
  printf '%s' "$1" | tr -d '\\' \
    | grep -o '"count": *"\{0,1\}[0-9][0-9]*' | head -1 | grep -o '[0-9][0-9]*'
}

# Sorted, comma-joined action list for one resource on one door.
actions_for() {  # $1 token, $2 door, $3 group, $4 resource
  mcp_help "$1" "$2" "$3" "$4" \
  | tr ',' '\n' | grep -o '\\"[a-z_]*\\"' | tr -d '\\"' \
  | grep -E '^(list|retrieve|create|update|partial_update|destroy|bulk_update|bulk_partial_update|bulk_destroy)$' \
  | sort -u | paste -sd, -
}
has_action()  { printf '%s' ",$1," | grep -q ",$2,"; }

echo "frisian-mcp demo — NetBox acceptance"
echo "  repo      $REPO_ROOT"
echo "  base url  $BASE_URL"

# ── 0. The stack is actually up ────────────────────────────────────────────
hdr "0. Reachability"
code=$(http_code "${BASE_URL}/login/")
if [ "$code" = "200" ]; then
  ok "login page reachable ($code)"
else
  bad "login page returned $code — the stack is not serving; nothing below is meaningful"
  echo; echo "FAIL — stack unreachable at $BASE_URL"; exit 1
fi

# ── 1. Migrations settled ──────────────────────────────────────────────────
#
# The application image and the baked database are two halves of one artifact.
# An unapplied migration here means they came from different builds — the exact
# state the single DEMO_TAG exists to prevent.
hdr "1. Migrations settled"
out=$(nmanage migrate --check 2>&1); rc=$?
if [ $rc -eq 0 ]; then
  ok "no unapplied migrations"
else
  bad "migrate --check exited $rc — image and database are from different builds"
  printf '%s\n' "$out" | sed 's/^/        /' | head -20
fi

# ── 2. Django system checks ────────────────────────────────────────────────
hdr "2. System checks"
# W016 is EXPECTED on a default boot and is allowed BY ID.
#
# It warns that heavy-response continuation entries share the default cache
# with OAuth authorization codes. Every demo host in this repo accepts it: none
# sets FRISIAN_MCP_HEAVY_CACHE_URL, because pointing a second alias at another
# logical DB of the same Redis silences the check without delivering the
# isolation it is about — the property needs a second Redis instance, which a
# single-compose demo does not have. The reasoning is written out in
# netbox/config/frisian_mcp.py and at length in nautobot/config/nautobot_config.py.
#
# Allowed by ID and not by relaxing the pattern: any OTHER warning, and every
# error, still fails here. An allowlist that reads `[EW][0-9]` would swallow
# the next finding too.
ALLOWED_FINDINGS="frisian_mcp.W016"

out=$(nmanage check 2>&1); rc=$?
findings=$(printf '%s' "$out" | grep -o 'frisian_mcp\.[EW][0-9][0-9]*' | sort -u)
unexpected=""
for f in $findings; do
  case " $ALLOWED_FINDINGS " in
    *" $f "*) ;;
    *) unexpected="$unexpected $f" ;;
  esac
done

if [ $rc -ne 0 ]; then
  bad "check exited $rc"
  printf '%s\n' "$out" | sed 's/^/        /' | head -20
elif [ -n "${unexpected# }" ]; then
  bad "check exited 0 but emitted unexpected frisian_mcp finding(s):${unexpected}"
  for f in $unexpected; do
    printf '%s\n' "$out" | grep -A2 "$f" | sed 's/^/        /' | head -6
  done
else
  ok "system checks clean (no error, no unexpected warning)"
  for f in $findings; do note "expected and accepted: $f"; done
fi

# ── 3. The wrapper mounted every route ─────────────────────────────────────
#
# NetBox is the one host where frisian-mcp does not mount its own URLs — it
# routes third-party URLs through PluginConfig, so the plugin wrapper does the
# mounting. If the wrapper is too old to read FRISIAN_MCP_ROUTES it mounts a
# single door and the three configured paths 404, with nothing logged.
# Asserted from the OUTSIDE, not from the log.
#
# The wrapper logs "mounted N route(s)" at INFO, and NetBox's logging config
# does not surface that logger at INFO — so the line is absent on a perfectly
# healthy stack. A log-line assertion here failed against a stack that was
# working, which is the worst kind of check: it trains you to ignore it.
#
# What actually distinguishes mounted from not-mounted, from outside: a mounted
# door answers 401 (authentication required), an unmounted path answers 404.
# The single-door fallback mounts FRISIAN_MCP_PATH instead, so on an old
# wrapper the three routes 404 and `/mcp/` answers — exactly inverted.
hdr "3. Routes mounted"
for d in "$DOOR_RO" "$DOOR_RW" "$DOOR_OPS"; do
  code=$(door_code "" "$d")
  [ "$code" = "404" ] && bad "/$d/ = 404 — not mounted. The wrapper may predate FRISIAN_MCP_ROUTES support." \
                      || ok "/$d/ is mounted (anonymous → $code, not 404)"
done
# The single-door fallback must NOT also be live. If it is, there is a fourth
# way in that carries no route ceiling at all.
code=$(door_code "" "mcp")
[ "$code" = "404" ] && ok "/mcp/ is absent — routes replaced the single door" \
                    || bad "/mcp/ answers $code — an unceilinged default door is still mounted alongside the routes"

logs=$(dc logs netbox 2>&1 | tail -400)
n=$(printf '%s' "$logs" | grep -o 'registered [0-9]* tools' | tail -1 | grep -o '[0-9]*')
if [ -n "${n:-}" ] && [ "$n" -gt 0 ]; then
  ok "registered $n tools"
else
  bad "no 'registered N tools' line, or N = 0"
fi
if printf '%s' "$logs" | grep -q 'mounted [0-9]* route'; then
  note "wrapper logged: $(printf '%s' "$logs" | grep -o 'mounted [0-9]* route.*' | tail -1)"
fi

# ── 4. Authentication ──────────────────────────────────────────────────────
hdr "4. Authentication"
for d in "$DOOR_RO" "$DOOR_RW" "$DOOR_OPS"; do
  code=$(door_code "" "$d")
  [ "$code" = "401" ] && ok "anonymous → /$d/ = 401" \
                      || bad "anonymous → /$d/ = $code, expected 401"
done
code=$(door_code "not-a-real-token" "$DOOR_RO")
[ "$code" = "401" ] && ok "bad token → /$DOOR_RO/ = 401" \
                    || bad "bad token → /$DOOR_RO/ = $code, expected 401"

code=$(door_code "$TOK_RO" "$DOOR_RO")
[ "$code" = "200" ] && ok "demo-readonly → /$DOOR_RO/ = 200" \
                    || bad "demo-readonly → /$DOOR_RO/ = $code, expected 200"
code=$(door_code "$TOK_NO" "$DOOR_RW")
[ "$code" = "200" ] && ok "demo-netops → /$DOOR_RW/ = 200" \
                    || bad "demo-netops → /$DOOR_RW/ = $code, expected 200"
code=$(door_code "$TOK_ADM" "$DOOR_OPS")
[ "$code" = "200" ] && ok "demo-admin → /$DOOR_OPS/ = 200" \
                    || bad "demo-admin → /$DOOR_OPS/ = $code, expected 200"

# ── 5. THE ROUTE CEILING ───────────────────────────────────────────────────
#
# One token. Two doors. The answers must differ.
#
# This is the check that distinguishes a correctly mounted set of routes from
# three URLs pointing at the same unfiltered view. Every other section in this
# file passes on both. Do not weaken it to "read-only offers list" — that is
# also true of the broken build; the assertion that matters is that the SAME
# credential is offered LESS on the lower door.
hdr "5. Route ceiling (one admin token, two doors)"
a_ro=$(actions_for "$TOK_ADM" "$DOOR_RO"  dcim site)
a_rw=$(actions_for "$TOK_ADM" "$DOOR_RW" dcim site)
note "read-only  : ${a_ro:-<empty>}"
note "read-write : ${a_rw:-<empty>}"

if [ -z "$a_ro" ] || [ -z "$a_rw" ]; then
  bad "could not read the action list from one or both doors"
elif [ "$a_ro" = "$a_rw" ]; then
  bad "IDENTICAL action lists on both doors — the routes are mounted but the
        ceiling is NOT being applied. The wrapper is almost certainly mounting
        the legacy gateway view once per path instead of a per-route view.
        See netbox/plugin/frisian_mcp_netbox/__init__.py."
else
  ok "the two doors offer different action sets"
fi
if has_action "$a_ro" create || has_action "$a_ro" destroy || has_action "$a_ro" update; then
  bad "the read-only door offers write actions to the admin token: $a_ro"
else
  ok "read-only door offers no write action, even to the admin token"
fi
has_action "$a_rw" create && ok "read-write door does offer create to the admin token" \
                          || bad "read-write door offers no create — the ceiling is too low"

# ── 6. Permission-aware discovery (principal, not route) ───────────────────
#
# Same door, same token, different resource. demo-netops' door permits the
# write tier across eight groups; the identity can write in two. What it is
# OFFERED must track the grant, not the door.
hdr "6. Principal filtering on one door"
n_dcim=$(actions_for "$TOK_NO" "$DOOR_RW" dcim site)
n_tenc=$(actions_for "$TOK_NO" "$DOOR_RW" tenancy tenant)
note "demo-netops · dcim/site      : ${n_dcim:-<empty>}"
note "demo-netops · tenancy/tenant : ${n_tenc:-<empty>}"
has_action "$n_dcim" create && ok "granted app (dcim) offers create" \
                            || bad "dcim offers no create to demo-netops — the write grant is missing"
if has_action "$n_tenc" create; then
  bad "ungranted app (tenancy) offers create — principal filtering is not applied"
else
  ok "ungranted app (tenancy) offers no create"
fi
# add+change and NOT delete. Absence of destroy on a GRANTED app is a sharper
# demonstration than the door ceiling, because the door does permit it.
if has_action "$n_dcim" destroy; then
  bad "dcim offers destroy to demo-netops — the grant is meant to be add+change only"
else
  ok "dcim offers no destroy — the grant is add+change, and it shows"
fi

# ── 7. Carve-outs ──────────────────────────────────────────────────────────
#
# `core` and `users` are the two groups the scoped routes deny. They reach the
# admin door and nothing else.
hdr "7. Route carve-outs"
t_ro=$(mcp_list_tools "$TOK_RO" "$DOOR_RO")
t_ops=$(mcp_list_tools "$TOK_ADM" "$DOOR_OPS")
for g in core users; do
  if printf '%s' "$t_ro" | grep -q "\"name\": *\"$g\""; then
    bad "group '$g' is offered on the read-only door — it is meant to be carved out"
  else
    ok "group '$g' absent from the read-only door"
  fi
  if printf '%s' "$t_ops" | grep -q "\"name\": *\"$g\""; then
    ok "group '$g' present on the ops door"
  else
    bad "group '$g' absent from the ops door — the carve-out removed it everywhere"
  fi
done

# ── 8. Writes and refusals ─────────────────────────────────────────────────
#
# Edits an existing description and restores it. See the residue note in the
# header for why this is not a create.
hdr "8. Write proof and refusals"
# VERIFIED BY READING BACK, not by matching the write's own response.
#
# A successful write returns the ADR-004 lean envelope — id, url, name,
# status_code, data_size, continuation_token — and deliberately does NOT echo
# the field that changed. Grepping the write response for the marker therefore
# fails on a write that fully succeeded, which is how this check was wrong the
# first time it ran.
MARK="acceptance-$$"
out=$(mcp "$TOK_NO" "$DOOR_RW" dcim site partial_update "{\"id\":1,\"description\":\"$MARK\"}")
if printf '%s' "$out" | grep -q '\\"status_code\\": 200'; then
  ok "demo-netops wrote dcim/site on the read-write door (200)"
  back=$(mcp "$TOK_RO" "$DOOR_RO" dcim site retrieve '{"id":1}')
  if printf '%s' "$back" | grep -q "$MARK"; then
    ok "the write is visible on read-back — it really landed"
  else
    bad "write returned 200 but the change is not visible on read-back"
  fi
  # Put it back. NetBox's Site.description defaults to an empty string.
  restore=$(mcp "$TOK_NO" "$DOOR_RW" dcim site partial_update '{"id":1,"description":""}')
  back=$(mcp "$TOK_RO" "$DOOR_RO" dcim site retrieve '{"id":1}')
  if printf '%s' "$restore" | grep -q '\\"status_code\\": 200' && ! printf '%s' "$back" | grep -q "$MARK"; then
    ok "description restored — no residue left in the estate"
  else
    bad "could NOT restore the description; the estate now carries $MARK on site 1"
  fi
else
  bad "demo-netops write failed: $(printf '%s' "$out" | head -c 200)"
fi

out=$(mcp "$TOK_NO" "$DOOR_RW" tenancy tenant create '{"name":"ShouldNotExist","slug":"shouldnotexist"}')
if printf '%s' "$out" | grep -q '403'; then
  ok "out-of-grant write refused 403 (principal denies)"
else
  bad "out-of-grant tenancy write was NOT refused with 403: $(printf '%s' "$out" | head -c 200)"
fi

out=$(mcp "$TOK_NO" "$DOOR_RO" dcim site create '{"name":"CeilingBreach","slug":"ceilingbreach","status":"active"}')
if printf '%s' "$out" | grep -q '404'; then
  ok "write on the read-only door refused 404 (ceiling removed the action)"
else
  bad "write on the read-only door was NOT refused with 404: $(printf '%s' "$out" | head -c 200)"
fi

out=$(mcp "$TOK_RO" "$DOOR_RO" dcim site create '{"name":"ReadOnlyBreach","slug":"readonlybreach","status":"active"}')
if printf '%s' "$out" | grep -q '404'; then
  ok "demo-readonly write refused 404"
else
  bad "demo-readonly write was NOT refused: $(printf '%s' "$out" | head -c 200)"
fi

# The two refusal SHAPES are different on purpose and both are correct:
#   403 — the tool is on this door, this principal may not use it
#   404 — the ceiling removed the tool from this door entirely
note "403 = principal denies · 404 = ceiling removed the action. Both are correct."

# ── 9. The estate is readable and is the expected one ──────────────────────
hdr "9. Estate"
out=$(mcp "$TOK_RO" "$DOOR_RO" dcim site list '{}')
n=$(extract_count "$out")
[ "${n:-0}" = "2" ] && ok "dcim/site list → 2" || bad "dcim/site list → ${n:-<none>}, expected 2"
out=$(mcp "$TOK_RO" "$DOOR_RO" dcim device list '{}')
n=$(extract_count "$out")
[ "${n:-0}" = "8" ] && ok "dcim/device list → 8" || bad "dcim/device list → ${n:-<none>}, expected 8"
out=$(mcp "$TOK_RO" "$DOOR_RO" ipam prefix list '{}')
n=$(extract_count "$out")
[ "${n:-0}" = "4" ] && ok "ipam/prefix list → 4" || bad "ipam/prefix list → ${n:-<none>}, expected 4"

# A filtered query must return a SUBSET. If a filter is silently ignored the
# count matches the unfiltered one, which reads as a working filter.
out=$(mcp "$TOK_RO" "$DOOR_RO" dcim device list '{"site":"dc1"}')
n=$(extract_count "$out")
[ "${n:-0}" = "4" ] && ok "dcim/device filtered by site=dc1 → 4 (a real subset)" \
                    || bad "dcim/device site=dc1 → ${n:-<none>}, expected 4"

# ── 10. The GUI login works ────────────────────────────────────────────────
#
# The demo is meant to be explored in a browser alongside the MCP surface, and
# a viewer who cannot log in has no way to check what an agent told them.
hdr "10. GUI login"
jar=$(mktemp)
csrf=$(curl -sS -c "$jar" "${BASE_URL}/login/" | grep -o 'name="csrfmiddlewaretoken" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"//')
if [ -z "$csrf" ]; then
  bad "no CSRF token on the login page"
else
  code=$(curl -sS -b "$jar" -c "$jar" -o /dev/null -w '%{http_code}' \
    -e "${BASE_URL}/login/" \
    -d "csrfmiddlewaretoken=$csrf&username=demo-readonly&password=$DEMO_PASSWORD" \
    "${BASE_URL}/login/")
  if [ "$code" = "302" ]; then
    ok "demo-readonly can log into the GUI (302 to the dashboard)"
  else
    bad "GUI login returned $code, expected a 302 redirect"
  fi
fi
rm -f "$jar"

# ── Verdict ────────────────────────────────────────────────────────────────
echo
if [ "$fail" -eq 0 ]; then
  echo "PASS — $checks checks, NetBox demo host is serving as specified."
  exit 0
else
  echo "FAIL — see above ($checks checks run)."
  exit 1
fi
