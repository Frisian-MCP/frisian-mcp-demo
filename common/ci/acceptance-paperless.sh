#!/usr/bin/env bash
#
# Acceptance checklist for the Paperless-ngx demo host.
#
# CONTRACT
# --------
# Invoked from anywhere, with no arguments and no required environment, after
# the true zero-flag boot:
#
#     cd paperless && docker compose up -d --wait
#     ./common/ci/acceptance-paperless.sh
#
# There is deliberately no flag, no profile and no -f chain that makes this
# pass. If acceptance needed one, the demo would be broken for every user
# regardless of whether CI was green — so the script is written to fail in that
# case rather than to accommodate it.
#
# WHY IT PARSES OUTPUT INSTEAD OF TRUSTING EXIT CODES
# ---------------------------------------------------
# Measured on the Nautobot host: `check` exits 0 while emitting a frisian_mcp
# warning. A check that only tested `$?` would report a clean system check on a
# config with a live warning. Every Django-level check below therefore inspects
# stdout as well as the exit code.
#
# WHY IT LEAVES NO RESIDUE
# ------------------------
# The write proof renames a tag and puts the name back, rather than creating an
# object. `demo-editor` holds add and change and NOT delete, so an object it
# creates cannot be removed by the identity that created it — a create-based
# proof would need the admin token to clean up, or would leak an object into
# the estate.
#
# BASH 3.2 COMPATIBLE on purpose (no associative arrays, no mapfile): CI runs
# ubuntu but this has to be runnable on a maintainer's macOS box.

set -uo pipefail

# ── Locate the repo and the compose project ────────────────────────────────
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
COMPOSE_DIR="$REPO_ROOT/paperless"

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  echo "::error::cannot find paperless/docker-compose.yml from $REPO_ROOT" >&2
  exit 2
fi

# Honour the committed .env so the script follows the port the user actually
# booted on, rather than assuming the default and reporting a false failure.
DEMO_BIND_HOST=127.0.0.1
DEMO_HTTP_PORT=8081
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
# Fixed constants provisioned by paperless/db/provision_identities.py and
# documented in paperless/README.md. Published by design; nothing here is a
# secret. If these stop matching the provisioner, MCP auth fails and this
# script is the thing that says so.
TOK_RO="frisian-demo-readonly-token-public-do-not-reuse"
TOK_ED="frisian-demo-editor-token-public-do-not-reuse"
TOK_ADM="frisian-demo-admin-token-public-do-not-reuse"
DEMO_PASSWORD="frisian-demo-public-password"

fail=0
checks=0
note() { printf '  %s\n' "$*"; }
ok()   { checks=$((checks+1)); printf '  ok    %s\n' "$*"; }
bad()  { checks=$((checks+1)); fail=1; printf '  FAIL: %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }

dc() { ( cd "$COMPOSE_DIR" && docker compose "$@" ); }
# Paperless's own tooling runs as the `paperless` user; running manage.py as
# root leaves root-owned files in the data directory that the services then
# cannot write.
pmanage() { dc exec -T --user paperless paperless python3 manage.py "$@"; }

# JSON-RPC tools/call against a door. $1 token, $2 route, $3 group,
# $4 resource, $5 action, $6 params-object
mcp() {
  curl -sS --max-time 120 -X POST \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":{\"resource\":\"$4\",\"action\":\"$5\",\"params\":$6}}}" \
    "${BASE_URL}/$2/"
}
# The `help` action on a dispatcher — the instrument that shows permission-
# aware discovery, because the per-identity difference lives in the action
# list rather than in the group list.
mcp_help() {
  curl -sS --max-time 120 -X POST \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":{\"action\":\"help\"}}}" \
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
# `grep -o | head -1` and NOT `sed 's/.*KEY.*/'`: `.*` is greedy, so the sed
# form silently returns the LAST match in the payload rather than the first.
extract_count()    { printf '%s' "$1" | grep -o '\\"count\\": [0-9][0-9]*' | head -1 | grep -o '[0-9][0-9]*'; }
extract_first_id() { printf '%s' "$1" | grep -o '\\"id\\": [0-9][0-9]*' | head -1 | grep -o '[0-9][0-9]*'; }

echo "frisian-mcp demo — Paperless acceptance"
echo "  repo      $REPO_ROOT"
echo "  base url  $BASE_URL"

# ── 0. The stack is actually up ────────────────────────────────────────────
hdr "0. Reachability"
code=$(http_code "${BASE_URL}/accounts/login/")
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
out=$(pmanage migrate --check 2>&1); rc=$?
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
# The warning baseline is ZERO and is asserted by NAME, not by count. If a
# warning is ever deliberately accepted, add it here with the ruling that
# accepted it — so an undeclared warning fifteen still fails loudly.
ACCEPTED_WARNINGS=""   # none accepted; clean is the baseline

hdr "2. System checks"
out=$(pmanage check 2>&1); rc=$?

errs=$(printf '%s\n' "$out"  | grep -oE '\(frisian_mcp\.E[0-9]+\)' | sort -u | tr '\n' ' ')
warns=$(printf '%s\n' "$out" | grep -oE '\(frisian_mcp\.W[0-9]+\)' | sort -u | tr '\n' ' ')

if [ -n "$errs" ]; then
  bad "frisian-mcp ERRORS present: $errs"
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
if [ -n "$(echo "$undeclared" | tr -d ' ')" ]; then
  bad "undeclared frisian-mcp warning(s):$undeclared"
  printf '%s\n' "$out" | grep -A2 -E '\(frisian_mcp\.W[0-9]+\)' | sed 's/^/        /'
else
  ok "no undeclared frisian-mcp warnings"
fi

if [ $rc -ne 0 ] && [ -z "$errs" ]; then
  bad "manage.py check exited $rc with no frisian_mcp error parsed — inspect manually"
fi

# ── 3. The posture is LOCKED ───────────────────────────────────────────────
#
# Every door refuses an unauthenticated caller. This is the single property the
# whole shipped configuration rests on, and it is one deleted settings line
# away from being false — so it is checked on every door rather than on the one
# door someone happened to think of.
hdr "3. The posture is locked"
for route in mcp/read-only mcp/read-write mcp/ops; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
    -H "Content-Type: application/json" -d '{}' "${BASE_URL}/${route}/")
  if [ "$code" = "401" ]; then ok "/$route refuses anonymous ($code)"
  else bad "/$route returned $code to an anonymous POST, expected 401"; fi
done

# A bad token must be refused too. A door that 401s on *no* credential and
# accepts *any* credential is not locked, and the first check alone cannot tell
# the difference.
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
  -H "Authorization: Bearer not-a-real-token" \
  -H "Content-Type: application/json" -d '{}' "${BASE_URL}/mcp/read-only/")
if [ "$code" = "401" ]; then ok "/mcp/read-only refuses an invalid bearer ($code)"
else bad "/mcp/read-only returned $code to an invalid bearer, expected 401"; fi

# ── 4. MCP surface per identity ────────────────────────────────────────────
#
# Asserted by NAME and exactly, so a group appearing or vanishing fails loudly.
#
# THE THREE SETS ARE DIFFERENT, AND THE MIDDLE ONE IS THE SMALLEST.
#
#   read-only    5   documents classification mail workflow monitoring
#   read-write   4   the same, MINUS workflow
#   ops          7   everything, plus sharing and system
#
# `system` and `sharing` are absent from both scoped doors' allow_list, and
# absent is byte-identical to never-registered: a caller cannot tell a
# carved-out group from one that does not exist in this Paperless at all.
#
# `workflow` is the interesting one. It is denied on the READ-WRITE door only,
# because a WorkflowAction carries webhook URLs, bodies and headers and the
# engine fires them on document events. On the read door those writes are
# already impossible — the `read` ceiling filters the action list — so the
# catalogue stays browsable there and vanishes from the more privileged door.
#
# It is a ROUTE-level deny, so it holds for every identity including the
# superuser. That is asserted separately below rather than inferred: an
# identity-dependent result here would mean the route model was not doing the
# work the demo says it is.
EXPECTED_READONLY_GROUPS="classification documents mail monitoring workflow"
EXPECTED_READWRITE_GROUPS="classification documents mail monitoring"
EXPECTED_ADMIN_GROUPS="classification documents mail monitoring sharing system workflow"

groups_on() { mcp_list_tools "$1" "$2" | grep -o '"name": "[a-z_]*"' | sed 's/"name": "//;s/"//' | sort -u | tr '\n' ' '; }

hdr "4. MCP surface per identity"
for triple in \
  "mcp/read-only|$TOK_RO|demo-readonly|$EXPECTED_READONLY_GROUPS" \
  "mcp/read-write|$TOK_ED|demo-editor|$EXPECTED_READWRITE_GROUPS" \
  "mcp/ops|$TOK_ADM|demo-admin|$EXPECTED_ADMIN_GROUPS"
do
  IFS='|' read -r route tok who want <<EOF
$triple
EOF
  got=$(echo $(groups_on "$tok" "$route"))
  want=$(echo $want)
  if [ "$got" = "$want" ]; then
    ok "$who on /$route exposes exactly: $got"
  else
    bad "$who on /$route group set differs
            got:  $got
            want: $want"
  fi
done

# The read-write door's smaller surface must be a ROUTE property, not a
# permission one. Asked as the superuser, whose permissions cannot be the
# reason anything is missing.
got=$(echo $(groups_on "$TOK_ADM" "mcp/read-write"))
if [ "$got" = "$(echo $EXPECTED_READWRITE_GROUPS)" ]; then
  ok "the read-write door is missing workflow for demo-admin too — it is the route, not the principal"
else
  bad "demo-admin sees '$got' on /mcp/read-write; the deny is supposed to be identity-independent"
fi

# ── 4b. The carve-out is ABSENCE, not refusal ──────────────────────────────
#
# `mailaccount` is on the scoped doors' deny_list because it stores an IMAP
# password. The demonstration is that a scoped caller cannot NAME it — so this
# checks the mail dispatcher's own help output rather than trying the call and
# reading a status code.
resp=$(mcp_help "$TOK_RO" "mcp/read-only" "mail")
if printf '%s' "$resp" | grep -q 'mailaccount'; then
  bad "mailaccount is visible on the read-only door's mail dispatcher — the deny_list is not holding"
else
  ok "mailaccount is absent from the read-only door's mail dispatcher"
fi

resp=$(mcp_help "$TOK_ADM" "mcp/ops" "mail")
if printf '%s' "$resp" | grep -q 'mailaccount'; then
  ok "mailaccount IS present on the admin door — the contrast is the demonstration"
else
  bad "mailaccount is absent on the admin door too; then the scoped doors prove nothing"
fi

# ── 5. The estate is what the corpus says ──────────────────────────────────
#
# Counted through MCP on the admin door, which exercises the read surface and
# the estate in one pass. seed/corpus.py is the oracle.
hdr "5. The estate"

ESTATE="
documents|document|24|the corpus
classification|correspondent|6|
classification|documenttype|6|
classification|tag|8|
classification|storagepath|3|
classification|customfield|3|
monitoring|savedview|2|owner-scoped: 2 per identity, and this is demo-admin's pair
workflow|workflow|1|disabled, local action only
sharing|sharelink|0|a ShareLink is a public unauthenticated URL; none ships
mail|mailaccount|0|a MailAccount is an IMAP password; none ships
"

while IFS='|' read -r grp res want why; do
  [ -z "${grp:-}" ] && continue
  resp=$(mcp "$TOK_ADM" "mcp/ops" "$grp" "$res" "list" '{"page_size":1}')
  got=$(extract_count "$resp")
  if [ -z "$got" ]; then
    bad "$grp/$res — could not read a count (surface error, not a count mismatch)"
    printf '%s\n' "$resp" | head -c 300 | sed 's/^/        /'
  elif [ "$got" = "$want" ]; then
    ok "$grp/$res = $got${why:+  ($why)}"
  else
    bad "$grp/$res = $got, the corpus says $want${why:+  ($why)}"
  fi
done <<EOF
$ESTATE
EOF

# ── 5b. Documents are FILED, not merely present ────────────────────────────
#
# A count is not evidence the estate demonstrates anything: twenty-four
# untitled documents with no correspondent satisfy `document = 24` and show
# nothing. This reads one document and checks it carries the metadata
# build_estate.py was supposed to apply.
# `ordering` is validated against each ViewSet's own ordering_fields, and the
# dispatcher rejects an unknown value outright rather than ignoring it. There
# is no `id` on any of these: documents order by `title`, the classification
# models by `name`. A wrong value here fails as "Invalid arguments", which
# reads like a broken call rather than a bad sort key.
resp=$(mcp "$TOK_ADM" "mcp/ops" "documents" "document" "list" '{"page_size":1,"ordering":"title"}')
if printf '%s' "$resp" | grep -q '\\"correspondent\\": null'; then
  bad "the first document has no correspondent — build_estate.py did not complete"
else
  ok "documents carry their correspondent"
fi

# ── 5c. The files the database points at are actually there ────────────────
#
# THE failure mode this host has and the Nautobot host does not. The estate is
# split across two images: the db image carries the SQL, the app image carries
# the media. Pull them at different tags — or build the app image without the
# estate artifact — and every listing works while every download 404s.
#
# Checked on disk rather than through a download, because a download also
# exercises permissions and content negotiation, and a failure there would not
# say which layer broke.
originals=$(dc exec -T paperless sh -c 'find /usr/src/paperless/media/documents/originals -type f 2>/dev/null | wc -l' | tr -dc '0-9')
if [ "${originals:-0}" -ge 24 ]; then
  ok "media tree restored: ${originals} original file(s) on disk"
else
  bad "only ${originals:-0} original file(s) on disk, expected at least 24 —
            the application image is missing its half of the estate, or the two
            images came from different builds"
fi

# ── 6. The permission gap — THIS IS THE DEMO ───────────────────────────────
#
# demo-editor's door permits the write tier across five groups. Its Django
# permissions permit writes to two models. The gap is the demonstration, and
# it shows up in DISCOVERY before it shows up in a refusal: permission-aware
# discovery rebuilds each dispatcher's action list per request, so the actions
# this identity cannot use are ABSENT rather than merely rejected.
hdr "6. The permission gap"

resp=$(mcp_help "$TOK_ED" "mcp/read-write" "classification")
# Both resources live in the SAME dispatcher, so this is not a route-level
# difference — it is one principal's permissions splitting one group's surface.
if printf '%s' "$resp" | grep -q 'tag'; then
  ok "demo-editor sees the tag resource on the classification dispatcher"
else
  bad "demo-editor cannot see the tag resource at all — the view grant is wrong"
fi

# The write proof. Rename a tag and put it back, so the estate is unchanged.
resp=$(mcp "$TOK_ED" "mcp/read-write" "classification" "tag" "list" '{"page_size":1,"ordering":"name"}')
tag_id=$(extract_first_id "$resp")
tag_name=$(printf '%s' "$resp" | grep -o '\\"name\\": \\"[^\\]*' | head -1 | sed 's/.*\\"//')
if [ -z "$tag_id" ] || [ -z "$tag_name" ]; then
  bad "could not read a tag to write to (id='$tag_id' name='$tag_name')"
else
  resp=$(mcp "$TOK_ED" "mcp/read-write" "classification" "tag" "partial_update" \
    "{\"id\":${tag_id},\"name\":\"${tag_name}-acceptance\"}")
  if printf '%s' "$resp" | grep -q "${tag_name}-acceptance"; then
    ok "demo-editor CAN write a tag (its grant covers documents.tag)"
  else
    bad "demo-editor could not write a tag, but its grant covers documents.tag"
    printf '%s\n' "$resp" | head -c 300 | sed 's/^/        /'
  fi
  # Put it back. This runs whether or not the write appeared to succeed —
  # a half-applied rename left in the estate is worse than a failed check.
  mcp "$TOK_ED" "mcp/read-write" "classification" "tag" "partial_update" \
    "{\"id\":${tag_id},\"name\":\"${tag_name}\"}" >/dev/null
  resp=$(mcp "$TOK_ADM" "mcp/ops" "classification" "tag" "retrieve" "{\"id\":${tag_id}}")
  if printf '%s' "$resp" | grep -q "\\\\\"name\\\\\": \\\\\"${tag_name}\\\\\""; then
    ok "the tag was restored — this script leaves no residue"
  else
    bad "the tag was NOT restored to '${tag_name}'; the estate has been modified"
  fi
fi

# The refusal proof, from the other direction. Same dispatcher, same door,
# same identity — a resource its permissions do not cover.
resp=$(mcp "$TOK_ED" "mcp/read-write" "classification" "correspondent" "list" '{"page_size":1,"ordering":"name"}')
corr_id=$(extract_first_id "$resp")
if [ -z "$corr_id" ]; then
  bad "demo-editor cannot even LIST correspondents; its view grant should cover them"
else
  resp=$(mcp "$TOK_ED" "mcp/read-write" "classification" "correspondent" "partial_update" \
    "{\"id\":${corr_id},\"name\":\"should-never-apply\"}")
  if printf '%s' "$resp" | grep -q 'should-never-apply'; then
    bad "demo-editor WROTE a correspondent. Its door permits the tier; its permissions do not
            permit the model, and the stricter of the two must win. THIS IS THE DEMO FAILING."
  else
    ok "demo-editor is REFUSED a correspondent write — door permits it, permissions do not"
  fi
fi

# ── 7. The read-only door has no write actions at all ──────────────────────
#
# Independent of any identity's permissions: the route's `read` ceiling filters
# the action list, so this holds even for the superuser token.
hdr "7. The read ceiling"
resp=$(mcp_help "$TOK_ADM" "mcp/read-only" "classification")
if printf '%s' "$resp" | grep -qE '(partial_update|"update"|"create"|"destroy")'; then
  bad "the read-only door offers a write action to demo-admin — the tier ceiling is not filtering"
else
  ok "the read-only door offers no write action, even to the admin token"
fi

# ── 8. The UI loads ────────────────────────────────────────────────────────
#
# The UI is part of the demo and the accounts are meant to be logged into, so
# this drives a real session login rather than only checking the login page
# renders.
hdr "8. UI"
CJ=$(mktemp); trap 'rm -f "$CJ"' EXIT

curl -sS -c "$CJ" -o /dev/null --max-time 60 "${BASE_URL}/accounts/login/"
CSRF=$(awk '/csrftoken/ {print $7}' "$CJ" | tail -1)
if [ -z "${CSRF:-}" ]; then
  bad "no CSRF cookie issued by /accounts/login/ — cannot test the authenticated UI"
else
  code=$(curl -sS -b "$CJ" -c "$CJ" -o /dev/null -w '%{http_code}' --max-time 60 \
    -e "${BASE_URL}/accounts/login/" \
    --data-urlencode "csrfmiddlewaretoken=$CSRF" \
    --data-urlencode "login=demo-admin" \
    --data-urlencode "password=$DEMO_PASSWORD" \
    "${BASE_URL}/accounts/login/")
  if [ "$code" = "302" ]; then
    ok "demo-admin session login (302 to the app)"
  else
    bad "demo-admin session login returned $code, expected 302 — the published password does not work"
  fi
fi

for path in / /api/documents/ /api/tags/ /api/correspondents/; do
  code=$(curl -sS -b "$CJ" -o /dev/null -w '%{http_code}' --max-time 60 "${BASE_URL}${path}")
  if [ "$code" = "200" ]; then ok "UI/API $path"
  else bad "UI/API $path returned $code"; fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS — ${checks} checks."
  exit 0
else
  echo "FAIL — see above (${checks} checks run)."
  exit 1
fi
