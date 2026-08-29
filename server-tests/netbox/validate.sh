#!/usr/bin/env bash
#
# Validate frisian-mcp against a running NetBox server-test stack.
#
#   ./validate.sh                      # defaults to http://localhost:8083
#   BASE_URL=http://host:port ./validate.sh
#
# Assumes the stack from server-tests/netbox/README.md is up, and that the two
# tokens below have been minted. It mints them itself if it can reach the
# container; otherwise it says what to run.
#
# BASH 3.2 COMPATIBLE (no associative arrays, no mapfile): CI is ubuntu, but
# this has to run on a maintainer's macOS box, which is where it was written.
#
# WHY IT DOES NOT TRUST A CLEAN LOG
# ---------------------------------
# The schema-derivation check counts startup warnings AND separately asserts a
# write action returns a real required-field error. Absence of warnings is not
# proof: a ViewSet whose schema derived to `{}` is silent too, and an empty
# schema imposes no validation, so the call still succeeds. Counting alone
# would report "fixed" for a surface that tells an agent nothing.
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8083}"
MCP="${BASE_URL}/api/mcp/"
CONTAINER="${NETBOX_CONTAINER:-development-netbox-1}"

TOK_ADMIN="frisian-netbox-servertest-admin-token"
TOK_SCOPED="frisian-netbox-servertest-scoped-token"

fail=0; checks=0
ok()   { checks=$((checks+1)); printf '  ok    %s\n' "$*"; }
bad()  { checks=$((checks+1)); fail=1; printf '  FAIL: %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }

rpc() { # $1 token, $2 json body
  curl -sS --max-time 120 -X POST \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d "$2" "$MCP"
}
code_for() { # $1 auth-header-value-or-empty
  if [ -n "$1" ]; then
    curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
      -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' "$MCP"
  else
    curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
      -H "Content-Type: application/json" -d '{}' "$MCP"
  fi
}

echo "frisian-mcp — NetBox server test"
echo "  base url  $BASE_URL"
echo "  container $CONTAINER"

# ── 0. Reachable ───────────────────────────────────────────────────────────
hdr "0. Reachability"
c=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$BASE_URL/" 2>/dev/null)
case "$c" in
  200|302) ok "NetBox answers ($c)" ;;
  *) bad "NetBox returned '$c' — nothing below is meaningful"; echo; echo "FAIL"; exit 1 ;;
esac

# ── 1. Identities ──────────────────────────────────────────────────────────
#
# The SCOPED principal is not a nicety. A superuser cannot demonstrate the
# description-vs-help property at all: the tier ceiling and the permission
# filter are both no-ops for it, so advertised and reachable agree trivially
# whether or not the code is correct.
hdr "1. Test identities"
if docker exec "$CONTAINER" true >/dev/null 2>&1; then
  docker exec -i "$CONTAINER" sh -c 'cd /opt/netbox/netbox && python manage.py shell' >/tmp/nbmint.out 2>&1 <<'PY'
from django.contrib.auth import get_user_model
from django.contrib.contenttypes.models import ContentType
from frisian_mcp.contrib.tokens.models import FrisianMcpToken, _hmac_token
from users.models import ObjectPermission
User = get_user_model()
admin = User.objects.filter(is_superuser=True).order_by("pk").first()
t, c = FrisianMcpToken.objects.get_or_create(
    token=_hmac_token("frisian-netbox-servertest-admin-token"),
    defaults={"name": "servertest-admin", "permission": "admin", "user": admin})
if not c:
    t.permission, t.user, t.is_active = "admin", admin, True; t.save()
# NetBox's User exposes some flags as read-only properties; a fresh non-super
# user already defaults correctly, so only touch what is settable.
u, _ = User.objects.get_or_create(username="scoped-tester")
u.is_active = True; u.save()
u.user_permissions.clear(); u.groups.clear()
ct = ContentType.objects.get(app_label="dcim", model="site")
op, _ = ObjectPermission.objects.get_or_create(
    name="scoped-view-site", defaults={"actions": ["view"], "enabled": True})
op.actions = ["view"]; op.enabled = True; op.save()
op.object_types.set([ct]); op.users.set([u]); op.groups.set([])
t2, c2 = FrisianMcpToken.objects.get_or_create(
    token=_hmac_token("frisian-netbox-servertest-scoped-token"),
    defaults={"name": "servertest-scoped", "permission": "read", "user": u})
if not c2:
    t2.permission, t2.user, t2.is_active = "read", u, True; t2.save()
print("MINTED admin=%s scoped=%s" % (admin.username, u.username))
PY
  if grep -q "^MINTED" /tmp/nbmint.out 2>/dev/null; then
    ok "$(grep '^MINTED' /tmp/nbmint.out)"
  else
    bad "could not mint tokens — see /tmp/nbmint.out"
  fi
else
  note "container '$CONTAINER' not reachable; assuming tokens already exist"
fi

# ── 2. The posture is locked ───────────────────────────────────────────────
hdr "2. Authentication"
c=$(code_for "");            [ "$c" = "401" ] && ok "anonymous refused ($c)"        || bad "anonymous returned $c, expected 401"
c=$(code_for "not-a-token"); [ "$c" = "401" ] && ok "invalid bearer refused ($c)"   || bad "invalid bearer returned $c, expected 401"
c=$(code_for "$TOK_ADMIN");  [ "$c" = "200" ] && ok "valid token accepted ($c)"     || bad "valid token returned $c, expected 200"

# ── 3. Surface ─────────────────────────────────────────────────────────────
hdr "3. Dispatch surface"
rpc "$TOK_ADMIN" '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' > /tmp/nb_adv_admin.json
n=$(python3 -c 'import json;print(len(json.load(open("/tmp/nb_adv_admin.json"))["result"]["tools"]))' 2>/dev/null)
if [ -n "${n:-}" ] && [ "$n" -gt 0 ]; then ok "admin sees $n dispatcher(s)"
else bad "could not read tools/list"; fi

# ── 4. Description must equal help, for BOTH principals ────────────────────
#
# The scoped run is the one that can fail. Advertised counts are computed from
# a filtered set; if that set is ever the route registry again, a scoped caller
# can subtract and learn the size of the surface hidden from it.
hdr "4. Advertised == reachable"
check_parity() { # $1 token, $2 label
  rpc "$1" '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' > /tmp/nb_adv.json
  groups=$(python3 -c 'import json;print(" ".join(t["name"] for t in json.load(open("/tmp/nb_adv.json"))["result"]["tools"]))' 2>/dev/null)
  [ -z "${groups:-}" ] && { bad "$2: no dispatchers returned"; return; }
  for g in $groups; do
    rpc "$1" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$g\",\"arguments\":{\"action\":\"help\"}}}" > "/tmp/nb_h_$g.json"
  done
  python3 - "$2" <<'PY'
import json, re, sys
label = sys.argv[1]
adv = json.load(open('/tmp/nb_adv.json'))["result"]["tools"]
bad = []
for t in adv:
    m = re.search(r"for (\d+) tools across (\d+) resources", t.get("description", ""))
    if not m:
        continue
    at, ar = int(m.group(1)), int(m.group(2))
    inner = json.loads(json.load(open('/tmp/nb_h_%s.json' % t["name"]))["result"]["content"][0]["text"])
    res = inner.get("resources", {})
    rt, rr = sum(len(v) for v in res.values()), len(res)
    if (at, ar) != (rt, rr):
        bad.append("%s advertises %d/%d, offers %d/%d" % (t["name"], at, ar, rt, rr))
if bad:
    print("MISMATCH " + label)
    for b in bad: print("    " + b)
else:
    print("PARITY %s (%d dispatchers)" % (label, len(adv)))
PY
}
out=$(check_parity "$TOK_ADMIN" "admin")
case "$out" in PARITY*) ok "$out" ;; *) bad "$out" ;; esac
out=$(check_parity "$TOK_SCOPED" "scoped principal")
case "$out" in PARITY*) ok "$out" ;; *) bad "$out" ;; esac

# ── 5. Schema derivation — counted AND probed ─────────────────────────────
hdr "5. Schema derivation"
if docker logs "$CONTAINER" >/dev/null 2>&1; then
  n=$(docker logs "$CONTAINER" 2>&1 | grep -c "schema derivation failed")
  [ "$n" -eq 0 ] && ok "no schema-derivation failures at startup" \
                 || bad "$n schema-derivation failure(s) at startup:
$(docker logs "$CONTAINER" 2>&1 | grep 'schema derivation failed' | sed 's/.*failed for /            /;s/ — falling.*//' | sort -u)"
fi
# The positive half: a write with no body must be REJECTED by a real schema.
# An empty schema would accept it, which is exactly the silent failure the
# warning count cannot see.
resp=$(rpc "$TOK_ADMIN" '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"dcim","arguments":{"resource":"device","action":"create","params":{}}}}')
if printf '%s' "$resp" | grep -q "required property"; then
  ok "write actions carry a real schema (empty create is rejected by name)"
else
  bad "dcim/device/create with an empty body was NOT rejected by a required-field
            check — the schema is probably empty, which no warning would reveal"
fi

# ── 6. Absolute URLs carry the caller's origin ─────────────────────────────
hdr "6. Absolute URL origin"
slug="validate-$$"
resp=$(rpc "$TOK_ADMIN" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dcim\",\"arguments\":{\"resource\":\"site\",\"action\":\"create\",\"params\":{\"name\":\"Validate ${slug}\",\"slug\":\"${slug}\",\"status\":\"active\"}}}}")
# The dispatcher returns its payload as an ESCAPED JSON string inside
# result.content[].text, so the status code appears as \"status_code\": 201.
# Matching the unescaped form finds nothing and reports a false failure on a
# call that actually succeeded.
if printf '%s' "$resp" | grep -q 'status_code\\": 201'; then
  ok "real write through the dispatcher returned 201"
else
  bad "write did not return 201: $(printf '%s' "$resp" | head -c 200)"
fi
origin=$(printf '%s' "$BASE_URL" | sed 's#^https\?://##')
url=$(printf '%s' "$resp" | grep -o '\\"url\\": \\"[^\\]*' | head -1 | sed 's/.*\\"//')
if [ -z "${url:-}" ]; then
  note "no url field in the response; skipping origin check"
elif printf '%s' "$url" | grep -q "$origin"; then
  ok "absolute URL carries the caller's origin: $url"
else
  bad "absolute URL does NOT carry the caller's origin
            got:  $url
            want: something containing $origin
            (this is the SERVER_NAME hardcode — see the README)"
fi

echo
if [ "$fail" -eq 0 ]; then echo "PASS — ${checks} checks."; exit 0
else echo "FAIL — see above (${checks} checks run)."; exit 1; fi
