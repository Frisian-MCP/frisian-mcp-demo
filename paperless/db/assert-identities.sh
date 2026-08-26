#!/usr/bin/env bash
#
# Assert the provisioned identity set, and the two estate properties that make
# the demo a demo.
#
# WHY IT IS SCHEMA-DRIVEN AND NOT A HARDCODED LIST
# ------------------------------------------------
# A hardcoded list is a check that expires silently the day the schema grows.
# So the sweep DISCOVERS credential-shaped tables by pattern and fails on
# anything populated that is not explicitly expected. Table fifteen cannot
# arrive unnoticed — a Paperless release that adds a token store gets caught
# by a check written before that store existed.
#
# It is an INDEPENDENT control, not a re-run of provisioning: it must not
# import or call provision_identities.py. A check that trusts the thing it is
# checking is not a check.
#
# Usage — it needs a reachable psql, not a database connection of its own:
#
#   cd paperless
#   docker compose cp db/assert-identities.sh db:/tmp/assert-identities.sh
#   docker compose exec -T db bash /tmp/assert-identities.sh
#
# The db image carries both bash 5 and psql, and `POSTGRES_USER` /
# `POSTGRES_DB` are already in its environment — so running it there needs no
# credentials on the command line and no port published to the host.
#
# Against a database reachable some other way, the standard libpq variables
# work:
#
#   PGHOST=127.0.0.1 PGPORT=5432 PGUSER=paperless PGPASSWORD=paperless \
#   PGDATABASE=paperless ./db/assert-identities.sh
set -euo pipefail

# Uses associative arrays and mapfile — bash 4.0+. macOS ships bash 3.2, so say
# so rather than failing with a confusing syntax error two hundred lines down.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "::error::this script requires bash 4.0+ (found ${BASH_VERSION:-unknown})." >&2
  echo "  macOS ships bash 3.2. \`brew install bash\` and re-run with that one," >&2
  echo "  or run it inside the db container." >&2
  exit 1
fi

# Inside the db container the connection details are in POSTGRES_*, not the
# libpq PG* variables psql actually reads. Bridging them here is what lets the
# documented `docker compose exec db` invocation work with no arguments — and
# it leaves an explicitly-set PG* alone, so the host-side invocation is
# unaffected.
export PGUSER="${PGUSER:-${POSTGRES_USER:-paperless}}"
export PGDATABASE="${PGDATABASE:-${POSTGRES_DB:-paperless}}"

PSQL=(psql -v ON_ERROR_STOP=1 -qtAX)
fail=0

note() { printf '  %s\n' "$*"; }
bad()  { printf '  FAIL: %s\n' "$*"; fail=1; }
q()    { "${PSQL[@]}" -c "$1"; }

echo "Asserting the provisioned identity set"

# ── 1. Discover every credential-shaped table actually present ─────────────
mapfile -t candidates < <(q "
  SELECT table_name FROM information_schema.tables
  WHERE table_schema = 'public'
    AND (   table_name LIKE '%token%'
         OR table_name LIKE '%oauth%'
         OR table_name LIKE '%secret%'
         OR table_name LIKE '%session%'
         OR table_name LIKE '%password%'
         OR table_name LIKE '%credential%'
         OR table_name LIKE 'socialaccount_%'
         OR table_name LIKE 'mfa_%'
         OR table_name LIKE 'account_%'
         OR table_name LIKE 'guardian_%'
         OR table_name LIKE 'authtoken_%'
         OR table_name IN ('auth_user','auth_user_groups',
                           'auth_user_user_permissions','django_admin_log',
                           'documents_sharelink','paperless_mail_mailaccount'))
  ORDER BY table_name;")

note "credential-shaped tables discovered: ${#candidates[@]}"

# ── 2. Tables allowed to be non-empty, with their exact expected counts ────
#
# Anything discovered above and NOT named here must be empty.
declare -A EXPECTED=(
  # THREE demo identities plus TWO that Paperless ships itself.
  #
  # CORRECTED after the first run, and the correction is the point. This said
  # 3, on the reasoning that the roster has three identities. Paperless ships
  # `AnonymousUser` (created by django-guardian) and `consumer` (the default
  # owner for consumed documents), and both are present on a pristine install
  # with zero provisioning.
  #
  # The fix is a NAMED baseline rather than a looser count — see section 3,
  # which lists all five by name, and section 3b, which asserts the two stock
  # ones cannot be logged into. A count of 5 alone is satisfied by two
  # attacker-supplied accounts.
  [auth_user]=5
  [frisian_mcp_tokens_frisianmcptoken]=3
  [frisian_mcp_oauth_oauthclient]=1            # the published browser client
  [frisian_mcp_oauth_oauthaccesstoken]=0
  [frisian_mcp_oauth_oauthauthorizeconsent]=0
  [auth_user_groups]=0                         # this roster binds permissions to USERS
  [documents_sharelink]=0                      # a ShareLink is a public, unauthenticated URL
  [paperless_mail_mailaccount]=0               # a MailAccount is an IMAP password
  # A session in the artifact would be a live, transferable login shipped
  # inside a published image.
  #
  # ⚠️ THIS IS ALSO WHY THIS SCRIPT RUNS AGAINST A FRESHLY BOOTED STACK.
  # Anything that logs in creates one, so running this after the acceptance
  # checklist — which drives a real UI login — reports a session that is not in
  # the artifact at all. Same for the audit log in section 11. `docker compose
  # restart` resets both, because the estate is restored on every start.
  [django_session]=0
)

# Row count is not fixed for the per-user permission M2M — it tracks how many
# models the scoped grants cover, which legitimately moves with the Paperless
# version. Asserted as "non-empty" rather than a magic number that would rot;
# the SHAPE of those grants is checked by name in section 7.
NONEMPTY_OK=(auth_user_user_permissions)

# ── 2b. OAuth: ship the durable half, never the perishable half ────────────
#
# The OAuth CLIENT is durable — it has no expiry, and it is what lets a viewer
# complete authorize and mint their own fresh token. It ships.
#
# An ACCESS TOKEN is not. `expires_at` is stamped at mint time against a
# package default, and for a published image mint time is BUILD time — so a
# baked access token ships already dead and reads to a user as "the demo is
# broken". Assert it is absent rather than shipping a credential with a clock
# on it.

in_list() { local n="$1"; shift; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

for t in "${candidates[@]}"; do
  n=$(q "SELECT count(*) FROM public.\"${t}\";")
  if [ -n "${EXPECTED[$t]+set}" ]; then
    want="${EXPECTED[$t]}"
    if [ "$n" -eq "$want" ]; then note "ok    ${t} = ${n}"
    else bad "${t} = ${n}, expected exactly ${want}"; fi
  elif in_list "$t" "${NONEMPTY_OK[@]}"; then
    if [ "$n" -gt 0 ]; then note "ok    ${t} = ${n} (non-empty as expected)"
    else bad "${t} is empty; the scoped grants cover no models"; fi
  else
    if [ "$n" -eq 0 ]; then note "ok    ${t} = 0"
    else bad "${t} = ${n}; credential-shaped, populated, and NOT expected"; fi
  fi
done

# ── 3. The identities are the RIGHT ones, not merely the right count ───────
#
# Three rows in auth_user is satisfied by three wrong users. Name them.
# The two stock accounts are named, not tolerated by a count. Naming them means
# a future Paperless adding a third fails loudly instead of widening the
# allowance silently.
STOCK_USERS="AnonymousUser,consumer"
ROSTER_USERS="demo-admin,demo-editor,demo-readonly"

actual=$(q "SELECT string_agg(username, ',' ORDER BY username) FROM auth_user;")
want=$(printf '%s\n%s\n' "${STOCK_USERS//,/$'\n'}" "${ROSTER_USERS//,/$'\n'}" | sort | paste -sd, -)
[ "$actual" = "$want" ] && note "ok    usernames = ${actual}" \
                        || bad "usernames = '${actual}', expected '${want}'"

# ── 3b. The stock accounts cannot be logged into ───────────────────────────
#
# A count of five is satisfied by five wrong users, and naming them is
# satisfied by a stock name with a working password behind it. Django marks an
# unusable password with a leading `!`; `consumer` ships with an EMPTY hash,
# which no hasher can identify and which therefore never matches either.
#
# Anything that looks like a real hash on one of these is a login the demo
# never documented.
n=$(q "SELECT count(*) FROM auth_user
       WHERE username IN ('AnonymousUser','consumer')
         AND password <> '' AND password NOT LIKE '!%';")
[ "$n" -eq 0 ] && note "ok    the stock accounts carry no usable password" \
               || bad "${n} stock account(s) carry a usable password — that is an undocumented login"

# ── 4. The build-only identity must never reach the artifact ───────────────
n=$(q "SELECT count(*) FROM auth_user WHERE username = 'demo-builder';")
[ "$n" -eq 0 ] && note "ok    demo-builder absent" \
               || bad "demo-builder is PRESENT — it must be deleted before the dump"

# ── 5. Exactly one superuser, and it is demo-admin ─────────────────────────
supers=$(q "SELECT coalesce(string_agg(username, ',' ORDER BY username), '') FROM auth_user WHERE is_superuser;")
[ "$supers" = "demo-admin" ] && note "ok    superusers = demo-admin" \
                             || bad "superusers = '${supers}', expected exactly 'demo-admin'"

# ── 6. Tiers are what the roster says ──────────────────────────────────────
tiers=$(q "SELECT string_agg(name || '=' || permission, ',' ORDER BY name)
           FROM frisian_mcp_tokens_frisianmcptoken;")
want_tiers="demo-admin=admin,demo-editor=read_write,demo-readonly=read"
[ "$tiers" = "$want_tiers" ] && note "ok    tiers = ${tiers}" \
                             || bad "tiers = '${tiers}', expected '${want_tiers}'"

# ── 7. demo-editor's write grant must stay NARROWER than its door ──────────
#
# THIS IS THE DEMO. Its door permits the write tier across five resource
# groups; this identity can write two models. If someone "fixes" a refusal by
# widening the grant, the demonstration quietly stops demonstrating anything —
# so it is asserted by name, not by count.
writes=$(q "
  SELECT coalesce(string_agg(DISTINCT ct.app_label || '.' || ct.model, ',' ORDER BY ct.app_label || '.' || ct.model), '')
  FROM auth_user u
  JOIN auth_user_user_permissions up ON up.user_id = u.id
  JOIN auth_permission p ON p.id = up.permission_id
  JOIN django_content_type ct ON ct.id = p.content_type_id
  WHERE u.username = 'demo-editor'
    AND (p.codename LIKE 'add\\_%' OR p.codename LIKE 'change\\_%' OR p.codename LIKE 'delete\\_%');")
want_writes="documents.document,documents.tag"
[ "$writes" = "$want_writes" ] && note "ok    demo-editor writes ${writes} only" \
                               || bad "demo-editor write models = '${writes}', expected '${want_writes}'"

# ── 8. demo-readonly must hold NO write permission at all ──────────────────
n=$(q "
  SELECT count(*)
  FROM auth_user u
  JOIN auth_user_user_permissions up ON up.user_id = u.id
  JOIN auth_permission p ON p.id = up.permission_id
  WHERE u.username = 'demo-readonly'
    AND p.codename NOT LIKE 'view\\_%';")
[ "$n" -eq 0 ] && note "ok    demo-readonly holds view permissions only" \
               || bad "demo-readonly holds ${n} non-view permission(s)"

# ── 9. Neither scoped identity may name the carved-out models ──────────────
#
# The route deny_list is one control; this is the independent second one. A
# grant on MailAccount or ShareLink would mean the two layers disagree, and the
# only reason they currently agree is that someone kept them parallel.
n=$(q "
  SELECT count(*)
  FROM auth_user u
  JOIN auth_user_user_permissions up ON up.user_id = u.id
  JOIN auth_permission p ON p.id = up.permission_id
  JOIN django_content_type ct ON ct.id = p.content_type_id
  WHERE u.username IN ('demo-readonly','demo-editor')
    AND (ct.app_label, ct.model) IN
        (VALUES ('paperless_mail','mailaccount'), ('documents','sharelink'));")
[ "$n" -eq 0 ] && note "ok    no scoped grant names mailaccount or sharelink" \
               || bad "${n} scoped grant(s) name a carved-out model"

# ── 10. The estate is actually there ───────────────────────────────────────
#
# An identity roster is perfect and useless against an empty database, and an
# empty database is exactly what a partially failed seed produces. This is the
# cheapest possible check that the artifact carries a demo.
docs=$(q "SELECT count(*) FROM documents_document;")
if [ "$docs" -gt 0 ]; then note "ok    documents = ${docs}"
else bad "documents_document is EMPTY — this artifact carries no estate"; fi

unfiled=$(q "SELECT count(*) FROM documents_document
             WHERE correspondent_id IS NULL OR document_type_id IS NULL;")
[ "$unfiled" -eq 0 ] && note "ok    every document has a correspondent and a type" \
                     || bad "${unfiled} document(s) are unfiled; build_estate.py did not complete"

# ── 11. The change log starts empty ────────────────────────────────────────
#
# Building the estate produces an audit record for every save. That is a
# build-time trail, not part of the demo — and it names demo-builder, which is
# supposed to have left no trace.
if [ "$(q "SELECT count(*) FROM information_schema.tables
           WHERE table_schema='public' AND table_name='auditlog_logentry';")" -eq 1 ]; then
  n=$(q "SELECT count(*) FROM auditlog_logentry;")
  [ "$n" -eq 0 ] && note "ok    audit log is empty" \
                 || bad "audit log carries ${n} record(s).
            If this ran after the acceptance checklist, those are ITS writes,
            not the artifact's — see the django_session note in section 2.
            \`docker compose restart\` resets the estate; re-run against that."
fi

echo
if [ "$fail" -eq 0 ]; then echo "PASS — provisioned identity set and estate are exactly as specified."; exit 0
else echo "FAIL — see above."; exit 1; fi
