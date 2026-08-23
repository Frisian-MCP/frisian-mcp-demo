#!/usr/bin/env bash
#
# D5 — acceptance checklist for the frisian-mcp demo estate.
#
# CONTRACT
# --------
# Invoked from the REPOSITORY ROOT, with no arguments and no required
# environment, after the true zero-flag boot:
#
#     cd nautobot && docker compose up -d --wait
#     ./common/ci/acceptance.sh
#
# There is deliberately no flag, no profile and no -f chain that makes this
# pass. If acceptance needed one, the demo would be broken for every user
# regardless of whether CI was green — so the script is written to fail in
# that case rather than to accommodate it.
#
# WHY IT PARSES OUTPUT INSTEAD OF TRUSTING EXIT CODES
# ---------------------------------------------------
# Measured, not assumed: `nautobot-server check` exits 0 while emitting
# frisian_mcp.W016. A check that only tested `$?` would report a clean system
# check on a config with a live warning — the same "silent no-op that reads as
# a fix" failure this project has already been bitten by once. Every Django-
# level check below therefore inspects stdout as well as the exit code.
#
# WHY IT LEAVES NO RESIDUE
# ------------------------
# The write proof mutates a field and puts it back, rather than creating an
# object. Two reasons, both measured:
#   1. `demo-netops-write` grants ["add","change"] and NOT "delete", so a
#      created object cannot be removed by the identity that created it. A
#      create-based proof would need the admin token to clean up, or would
#      leak an object into the golden dump.
#   2. This script runs against the pre-B5 estate as well as against throwaway
#      CI containers. Anything it leaves behind ships in the artifact.
#
# BASH 3.2 COMPATIBLE on purpose (no associative arrays, no mapfile): CI runs
# ubuntu but this has to be runnable on a maintainer's macOS box, which is
# where it was first run.

set -uo pipefail

# ── Locate the repo and the compose project ────────────────────────────────
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
COMPOSE_DIR="$REPO_ROOT/nautobot"

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  echo "::error::cannot find nautobot/docker-compose.yml from $REPO_ROOT" >&2
  exit 2
fi

# Honour the committed .env so the script follows the port the user actually
# booted on, rather than assuming the default and reporting a false failure.
DEMO_BIND_HOST=127.0.0.1
DEMO_HTTP_PORT=8080
if [ -f "$COMPOSE_DIR/.env" ]; then
  v=$(grep -E '^DEMO_BIND_HOST=' "$COMPOSE_DIR/.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')
  [ -n "${v:-}" ] && DEMO_BIND_HOST="$v"
  v=$(grep -E '^DEMO_HTTP_PORT=' "$COMPOSE_DIR/.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')
  [ -n "${v:-}" ] && DEMO_HTTP_PORT="$v"
fi
# 0.0.0.0 is a bind address, not a destination.
[ "$DEMO_BIND_HOST" = "0.0.0.0" ] && DEMO_BIND_HOST=127.0.0.1
BASE_URL="http://${DEMO_BIND_HOST}:${DEMO_HTTP_PORT}"

# ── Published demo credentials ─────────────────────────────────────────────
# Fixed constants provisioned by nautobot/db/provision_identities.py and
# documented in nautobot/README.md. Published by design; nothing here is a
# secret. If these stop matching the provisioner, MCP auth fails and this
# script is the thing that says so.
TOK_RO="frisian-demo-readonly-token-public-do-not-reuse"
TOK_NET="frisian-demo-netops-token-public-do-not-reuse"
TOK_ADM="frisian-demo-admin-token-public-do-not-reuse"
DEMO_PASSWORD="frisian-demo-public-password"

fail=0
checks=0
note() { printf '  %s\n' "$*"; }
ok()   { checks=$((checks+1)); printf '  ok    %s\n' "$*"; }
bad()  { checks=$((checks+1)); fail=1; printf '  FAIL: %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }

dc() { ( cd "$COMPOSE_DIR" && docker compose "$@" ); }

# JSON-RPC tools/call against a door. $1 token, $2 route, $3 group,
# $4 resource, $5 action, $6 params-object
mcp() {
  curl -sS --max-time 120 -X POST \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":{\"resource\":\"$4\",\"action\":\"$5\",\"params\":$6}}}" \
    "${BASE_URL}/$2/"
}
mcp_list_tools() {
  curl -sS --max-time 120 -X POST \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
    "${BASE_URL}/$2/"
}
http_code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 60 "$@"; }

# The dispatcher returns its payload as an escaped JSON string inside
# result.content[].text, so values are pulled with a tolerant matcher rather
# than by decoding two layers of JSON without a parser dependency.
#
# These use `grep -o | head -1` and NOT `sed 's/.*KEY.*/'`. Learned on the
# first run: `.*` is greedy, so the sed form silently returns the LAST match
# in the payload rather than the first — which handed the write proof the id
# of a nested related object and produced "No Device matches the given query".
extract_count() { printf '%s' "$1" | grep -o '\\"count\\": [0-9][0-9]*' | head -1 | grep -o '[0-9][0-9]*'; }
extract_first_id() { printf '%s' "$1" | grep -o '\\"id\\": \\"[0-9a-f-]\{36\}\\"' | head -1 | grep -o '[0-9a-f-]\{36\}'; }

echo "frisian-mcp demo — acceptance"
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
hdr "1. Migrations settled"
out=$(dc exec -T nautobot nautobot-server migrate --check 2>&1); rc=$?
if [ $rc -eq 0 ]; then
  ok "migrate --check is clean (no unapplied migrations)"
else
  bad "migrate --check exited $rc — the image and the baked database disagree"
  printf '%s\n' "$out" | tail -20 | sed 's/^/        /'
fi

# ── 2. System checks ───────────────────────────────────────────────────────
#
# Severity convention (frisian-mcp checks.py): Warning = config hygiene,
# Error = indeterminate security metadata on a dispatcher. An E00x is a stop.
#
# The warning baseline is ZERO and is asserted by NAME, not by count. The
# W016 heavy-cache warning was closed by pointing FRISIAN_MCP_HEAVY_CACHE_URL
# at a dedicated redis-heavy service; a config that regresses that must fail
# here rather than pass with a warning nobody reads. If a warning is ever
# deliberately accepted, add it to ACCEPTED_WARNINGS with the ruling that
# accepted it — so an undeclared warning fifteen still fails loudly.
ACCEPTED_WARNINGS=""   # none accepted; clean is the baseline

hdr "2. System checks"
out=$(dc exec -T nautobot nautobot-server check 2>&1); rc=$?

errs=$(printf '%s\n' "$out" | grep -oE '\(frisian_mcp\.E[0-9]+\)' | sort -u | tr '\n' ' ')
warns=$(printf '%s\n' "$out" | grep -oE '\(frisian_mcp\.W[0-9]+\)' | sort -u | tr '\n' ' ')

if [ -n "$errs" ]; then
  bad "frisian-mcp ERRORS present: $errs (an E00x is a stop; the entrypoint hard-exits on these)"
else
  ok "no frisian-mcp errors"
fi

undeclared=""
for w in $warns; do
  case " $ACCEPTED_WARNINGS " in
    *" $w "*) note "declared warning accepted: $w" ;;
    *)        undeclared="$undeclared $w" ;;
  esac
done
if [ -n "${undeclared// /}" ]; then
  bad "undeclared frisian-mcp warning(s):$undeclared"
  printf '%s\n' "$out" | grep -A2 -E '\(frisian_mcp\.W[0-9]+\)' | sed 's/^/        /'
else
  ok "no undeclared frisian-mcp warnings"
fi

# Exit code is checked too, but only as a supplement — see header.
if [ $rc -ne 0 ] && [ -z "$errs" ]; then
  bad "nautobot-server check exited $rc with no frisian_mcp error parsed — inspect manually"
fi

# ── 3. Estate matches the B2 spec ──────────────────────────────────────────
#
# Counted through MCP on the admin door, which exercises the read surface and
# the estate in one pass. The B2 spec is the oracle, per the D5 reshape —
# there is no prior baseline to diff against because the estate did not exist
# before we built it.
#
# Format: group|resource|expected|note
# An expected value of "-" means "declared deviation, see DEVIATIONS below".
hdr "3. Estate matches the B2 spec"

ESTATE="
dcim|device|14|B2 tier B
dcim|interface|424|B2 tier B; dc1-leaf-01/02 at full 48
dcim|location|4|DC1, DC2, BR1 + parent
dcim|rack|4|
ipam|prefix|10|
ipam|vlan|6|
ipam|ipaddress|14|
circuits|circuit|2|DC1<->DC2, DC1<->BR1
circuits|circuittermination|4|
tenancy|tenant|2|Corporate, Research
bgp|autonomoussystem|2|
dns|dnszone|1|
dns|arecord|2|
golden_config|goldenconfigsetting|1|
"

while IFS='|' read -r grp res want why; do
  [ -z "${grp:-}" ] && continue
  resp=$(mcp "$TOK_ADM" "mcp/admin" "$grp" "$res" "list" '{"limit":1}')
  got=$(extract_count "$resp")
  if [ -z "$got" ]; then
    bad "$grp/$res — could not read a count (surface error, not a count mismatch)"
    printf '%s\n' "$resp" | head -c 200 | sed 's/^/        /'
  elif [ "$got" = "$want" ]; then
    ok "$grp/$res = $got${why:+  ($why)}"
  else
    bad "$grp/$res = $got, B2 spec says $want${why:+  ($why)}"
  fi
done <<EOF
$ESTATE
EOF

# ── 3b. Declared deviations from the B2 spec ───────────────────────────────
#
# 🔴 RULED 2026-08-23 — BUILD ALL FOUR. Opened as B4b (42cd443b), nautobot
# seat. They were NOT scoped out, so these assertions stay RED until the
# objects exist. That is the correct state for a checklist to sit in while the
# work it is waiting on is open, and it is why there is no flag here to make
# it green early.
#
# The deciding argument was B2's own: tier B was chosen over tier A because
# "cable topology is non-trivial", so scoping cables out would retroactively
# empty the reason the scale was picked. The compliance rule was asked for
# specifically so the plugin "has something to show".
#
# HOW THEY WERE MISSED, because that is the part worth keeping: all four are
# named in the B2 build order, are EMPTY in the built estate, and produced
# ZERO calls in b4_build/*.jsonl — not attempts, not refusals, not errors.
# B4's record stated "Deviations from the B2 spec: None in the estate." A gap
# that generates no signal at all is a different failure mode from one that
# fails loudly, and it is the reason this check counts objects rather than
# reading a build log.
#
# WHEN B4b LANDS: move these four rows up into the ESTATE table with their
# real expected counts and delete this block. It exists for categories that
# are legitimately empty; after B4b, none of them are.
DEVIATIONS="
dcim|cable|0|B2 step 7 — pending B4b, never attempted in B4
ipam|ipaddresstointerface|0|B2 step 9 — pending B4b, never attempted in B4
bgp|peering|0|B2 step 11 — pending B4b, ASNs exist but no peerings
golden_config|compliancerule|0|B2 step 13 — pending B4b, settings exist but no rule
"
# 1 while B4b is open. There is deliberately no path that turns these green
# without the objects existing.
UNRULED_DEVIATIONS=1

hdr "3b. B2 categories that are empty"
while IFS='|' read -r grp res want why; do
  [ -z "${grp:-}" ] && continue
  resp=$(mcp "$TOK_ADM" "mcp/admin" "$grp" "$res" "list" '{"limit":1}')
  got=$(extract_count "$resp")
  if [ "$got" = "$want" ] && [ "$UNRULED_DEVIATIONS" -eq 0 ]; then
    ok "$grp/$res = $got  ($why)"
  elif [ "$got" = "$want" ]; then
    bad "$grp/$res = $got  ($why)"
  else
    ok "$grp/$res = $got — no longer empty; update the DEVIATIONS block ($why)"
  fi
done <<EOF
$DEVIATIONS
EOF

# ── 4. UI loads ────────────────────────────────────────────────────────────
#
# The UI is part of the demo and the accounts are meant to be logged into, so
# this drives a real session login rather than only checking the login page
# renders. One list view per core app and one detail view per plugin.
hdr "4. UI loads"
CJ=$(mktemp); trap 'rm -f "$CJ"' EXIT

curl -sS -c "$CJ" -o /dev/null --max-time 60 "${BASE_URL}/login/"
CSRF=$(awk '/csrftoken/ {print $7}' "$CJ" | tail -1)
if [ -z "${CSRF:-}" ]; then
  bad "no CSRF cookie issued by /login/ — cannot test the authenticated UI"
else
  code=$(curl -sS -b "$CJ" -c "$CJ" -o /dev/null -w '%{http_code}' --max-time 60 \
    -e "${BASE_URL}/login/" \
    --data-urlencode "csrfmiddlewaretoken=$CSRF" \
    --data-urlencode "username=demo-admin" \
    --data-urlencode "password=$DEMO_PASSWORD" \
    --data-urlencode "next=/" \
    "${BASE_URL}/login/")
  if [ "$code" = "302" ]; then
    ok "demo-admin session login (302 to the app)"
  else
    bad "demo-admin session login returned $code, expected 302 — the published password does not work"
  fi
fi

# path|label. Plugin views are the "one detail view per plugin" requirement;
# Nautobot renders these under /plugins/.
UI_PATHS="
/|home
/dcim/devices/|dcim list
/ipam/prefixes/|ipam list
/circuits/circuits/|circuits list
/extras/tags/|extras list
/plugins/bgp/autonomous-systems/|plugin: bgp
/plugins/dns/dns-zones/|plugin: dns
/plugins/golden-config/config-compliance/|plugin: golden-config
"
while IFS='|' read -r path label; do
  [ -z "${path:-}" ] && continue
  code=$(curl -sS -b "$CJ" -o /dev/null -w '%{http_code}' --max-time 60 "${BASE_URL}${path}")
  if [ "$code" = "200" ]; then ok "UI $label ($path)"
  else bad "UI $label ($path) returned $code"; fi
done <<EOF
$UI_PATHS
EOF

# ── 5. MCP surface per identity ────────────────────────────────────────────
#
# The scoped doors expose TWELVE groups, not the thirteen in the route
# allow_list. `load_balancers` is allowed by the route but absent from
# SCOPED_APP_LABELS in the provisioner, so permission-aware discovery hides
# it — route allowance and principal grant are independent, which is the same
# property the write proof below demonstrates from the other direction.
#
# Asserted by NAME and exactly, so a group appearing or vanishing fails loudly.
EXPECTED_SCOPED_GROUPS="bgp circuits cloud dcim dns extras golden_config ipam ssot tenancy virtualization wireless"

hdr "5. MCP surface per identity"
for pair in "mcp/read-only:$TOK_RO:demo-readonly" "mcp/read-write:$TOK_NET:demo-netops"; do
  route=${pair%%:*}; rest=${pair#*:}; tok=${rest%%:*}; who=${rest#*:}
  got=$(mcp_list_tools "$tok" "$route" | grep -o '"name": "[a-z_]*"' | sed 's/"name": "//;s/"//' | sort -u | tr '\n' ' ')
  got=$(echo $got)
  if [ "$got" = "$EXPECTED_SCOPED_GROUPS" ]; then
    ok "$who on /$route exposes exactly the 12 scoped groups"
  else
    bad "$who on /$route group set differs
            got:  $got
            want: $EXPECTED_SCOPED_GROUPS"
  fi
done

# The admin door must expose what the scoped doors made absent. That contrast
# is the demonstration, so it is asserted rather than assumed.
adm_groups=$(mcp_list_tools "$TOK_ADM" "mcp/admin" | grep -o '"name": "[a-z_]*"' | sed 's/"name": "//;s/"//' | sort -u)
for g in users vpn load_balancers; do
  if printf '%s\n' "$adm_groups" | grep -qx "$g"; then
    ok "admin door exposes '$g' (absent on the scoped doors — the contrast)"
  else
    bad "admin door is missing '$g'; the scoped/admin contrast no longer demonstrates anything"
  fi
done

# One read call per group actually succeeds on the read-only door.
for g in $EXPECTED_SCOPED_GROUPS; do
  case $g in
    dcim) r=device ;; ipam) r=prefix ;; circuits) r=circuit ;; tenancy) r=tenant ;;
    virtualization) r=cluster ;; wireless) r=wirelessnetwork ;; cloud) r=cloudaccount ;;
    golden_config) r=goldenconfigsetting ;; dns) r=dnszone ;; bgp) r=autonomoussystem ;;
    ssot) r=sync ;; extras) r=status ;;
  esac
  resp=$(mcp "$TOK_RO" "mcp/read-only" "$g" "$r" "list" '{"limit":1}')
  if [ -n "$(extract_count "$resp")" ]; then
    ok "read call succeeds: $g/$r"
  else
    bad "read call failed: $g/$r — $(printf '%s' "$resp" | head -c 160)"
  fi
done

# ══════════════════════════════════════════════════════════════════════════
# MANDATORY AND BLOCKING. All three were proven live during B4, so a failure
# here is a REGRESSION between that run and this image — which is exactly
# what CI needs this script to catch on every build.
# ══════════════════════════════════════════════════════════════════════════

# ── M1. FRISIAN_MCP_ROUTES was actually read ───────────────────────────────
#
# Both halves matter and only the pair is conclusive. On a package that
# ignores FRISIAN_MCP_ROUTES (measured on 1.0.12) the three doors silently
# collapse onto the default /mcp/ mount and every one of them still answers a
# clean 401 from outside — so "read-only is not 404" alone can be satisfied by
# the broken case. Asserting that /mcp/ IS 404 is what distinguishes them:
# this config sets no FRISIAN_MCP_PATH, so the default mount must not exist.
hdr "M1. MANDATORY — the per-route doors are really mounted"
for p in "mcp/read-only" "mcp/read-write" "mcp/admin"; do
  code=$(http_code -X POST -H 'Content-Type: application/json' \
          -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' "${BASE_URL}/${p}/")
  if [ "$code" = "404" ]; then
    bad "/$p is 404 — FRISIAN_MCP_ROUTES was NOT read; the doors have collapsed"
  elif [ "$code" = "401" ]; then
    ok "/$p mounted and closed to anonymous callers ($code)"
  else
    bad "/$p returned $code — expected 401 (mounted, authenticated)"
  fi
done
code=$(http_code -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' "${BASE_URL}/mcp/")
if [ "$code" = "404" ]; then
  ok "/mcp/ is 404 — the default mount is absent, so the doors did not collapse onto it"
else
  bad "/mcp/ returned $code — a default mount exists; FRISIAN_MCP_PATH is set or ROUTES was ignored"
fi

# ── M2. The carve-out refuses, rather than merely being configured ─────────
#
# A control that has never been observed refusing is not a control. The
# control case matters as much as the refusal: without it, a door that is
# broken for every resource would pass this check.
hdr "M2. MANDATORY — read-tier token is refused on extras/secret"
resp=$(mcp "$TOK_RO" "mcp/read-only" "extras" "secret" "list" '{}')
if printf '%s' "$resp" | grep -q "Unknown tool 'secret_list' in group 'extras'"; then
  ok "extras/secret is ABSENT on the read-only door (route deny_list — the silent, stronger control)"
elif printf '%s' "$resp" | grep -q '"isError": true'; then
  ok "extras/secret refused on the read-only door (non-canonical message; inspect)"
  note "response: $(printf '%s' "$resp" | head -c 200)"
else
  bad "extras/secret was NOT refused on the read-only door — the carve-out is not holding"
  note "response: $(printf '%s' "$resp" | head -c 300)"
fi
resp=$(mcp "$TOK_RO" "mcp/read-only" "extras" "status" "list" '{"limit":1}')
if [ -n "$(extract_count "$resp")" ]; then
  ok "control: an ALLOWED extras resource still reads (the door is not simply broken)"
else
  bad "control failed: extras/status does not read, so the refusal above proves nothing"
fi

# ── M3. Door ceiling and principal grants are independent ─────────────────
#
# The demo's central claim, in three calls. demo-netops holds a read_write
# token on the read-write door: the door allows writes across all thirteen
# scoped resources, its ObjectPermissions allow writes to two of them.
#
# The write proof is an update-and-restore, not a create — see the header.
hdr "M3. MANDATORY — demo-netops refused a write its door allows"

# (a) refused where the grant does not reach
resp=$(mcp "$TOK_NET" "mcp/read-write" "dns" "dnszone" "create" '{"name":"acceptance-probe.invalid"}')
if printf '%s' "$resp" | grep -q "You do not have permission to use 'dnszone'/'create' in group 'dns'"; then
  ok "dns/dnszone create REFUSED for demo-netops (Django ObjectPermission — the layer that names what you cannot do)"
elif printf '%s' "$resp" | grep -q '"isError": true'; then
  bad "dns/dnszone create failed for demo-netops, but not with the expected permission refusal"
  note "response: $(printf '%s' "$resp" | head -c 250)"
else
  bad "dns/dnszone create SUCCEEDED for demo-netops — the grant is wider than the demo claims. Estate polluted; remove the zone."
fi

# (b) succeeds where the grant does reach — reversible
# `serial` is the probe field, chosen by measurement rather than taste:
#
#   * `description` cannot be used. The ADR-004 write envelope returns only
#     {id, url, name, status_code, data_size, continuation_token}, so an
#     update never echoes it back; `description` is also absent from the
#     device serializer output AND is not a filterable field ("Unknown filter
#     field"), so there is no way to re-read it. A proof that asserted on the
#     write response alone would be asserting on the exit status of the thing
#     that made the change, which is not evidence.
#   * `serial` IS returned by `retrieve`, so setting it and reading it back is
#     a true re-read of the live surface, and it is empty across the whole B4
#     estate so restoring to "" is lossless.
dev=$(mcp "$TOK_NET" "mcp/read-write" "dcim" "device" "list" '{"limit":1}')
dev_id=$(extract_first_id "$dev")
if [ -z "${dev_id:-}" ]; then
  bad "could not read a device id as demo-netops — cannot run the write proof"
else
  before=$(mcp "$TOK_NET" "mcp/read-write" "dcim" "device" "retrieve" "{\"id\":\"$dev_id\"}")
  # The restore writes an empty serial back, which is only correct if it was
  # empty to begin with. Asserted, never assumed: acceptance must not clobber
  # a serial someone meant to keep.
  if ! printf '%s' "$before" | grep -q '\\"serial\\": \\"\\"'; then
    bad "device $dev_id already carries a serial; refusing to run the write proof rather than overwrite it"
  else
    probe="ACC-PROBE-$$"
    resp=$(mcp "$TOK_NET" "mcp/read-write" "dcim" "device" "partial_update" "{\"id\":\"$dev_id\",\"serial\":\"$probe\"}")
    after=$(mcp "$TOK_NET" "mcp/read-write" "dcim" "device" "retrieve" "{\"id\":\"$dev_id\"}")
    if printf '%s' "$after" | grep -q "$probe"; then
      ok "dcim/device update SUCCEEDED for demo-netops, confirmed by re-read (same door, same tier, different grant)"
    else
      bad "dcim/device update did not take for demo-netops — its own grant is not holding"
      note "write response: $(printf '%s' "$resp" | head -c 250)"
    fi
    # Restore unconditionally, then confirm the restore by re-read too.
    mcp "$TOK_NET" "mcp/read-write" "dcim" "device" "partial_update" "{\"id\":\"$dev_id\",\"serial\":\"\"}" >/dev/null
    restored=$(mcp "$TOK_NET" "mcp/read-write" "dcim" "device" "retrieve" "{\"id\":\"$dev_id\"}")
    if printf '%s' "$restored" | grep -q "$probe"; then
      bad "RESTORE FAILED — device $dev_id still carries serial '$probe' on re-read. Clear it before the golden dump."
    else
      ok "write proof restored, confirmed by re-read; acceptance leaves no residue"
    fi
  fi

  # (c) the grant is ["add","change"] and deliberately NOT "delete". Locked so
  # that widening it to make some future cleanup convenient fails here.
  resp=$(mcp "$TOK_NET" "mcp/read-write" "dcim" "device" "destroy" "{\"id\":\"$dev_id\"}")
  if printf '%s' "$resp" | grep -q "You do not have permission to use 'device'/'destroy' in group 'dcim'"; then
    ok "dcim/device destroy REFUSED for demo-netops (grant is add+change, never delete)"
  else
    bad "dcim/device destroy was NOT refused for demo-netops — the write grant has been widened to include delete"
    note "response: $(printf '%s' "$resp" | head -c 250)"
  fi
fi

# ── Verdict ────────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────────────────────────"
if [ "$fail" -eq 0 ]; then
  echo "PASS — $checks checks, all green."
  exit 0
else
  echo "FAIL — see above ($checks checks run)."
  exit 1
fi
