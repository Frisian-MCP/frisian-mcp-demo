#!/usr/bin/env bash
#
# Assert the provisioned identity set, and the estate properties that make the
# demo a demo.
#
# WHY IT IS SCHEMA-DRIVEN AND NOT A HARDCODED LIST
# ------------------------------------------------
# A hardcoded list is a check that expires silently the day the schema grows.
# So the sweep DISCOVERS credential-shaped tables by pattern and fails on
# anything populated that is not explicitly expected. A NetBox release that
# adds a token store gets caught by a check written before that store existed.
#
# It is an INDEPENDENT control, not a re-run of provisioning: it must not
# import or call provision_identities.py. A check that trusts the thing it is
# checking is not a check.
#
# HOW NETBOX DIFFERS FROM THE OTHER DEMO HOSTS
# --------------------------------------------
# NetBox does not grant through Django's `auth_user_user_permissions` M2M —
# that table is empty here and asserting on it would pass vacuously forever.
# Permissions come from NetBox's own `users.ObjectPermission`: a named row
# carrying an `actions` array, joined to users and to the content types it
# covers. Sections 6-9 read that model instead, which is why they look nothing
# like the Paperless script's equivalents.
#
# Usage — it needs a reachable psql, not a database connection of its own:
#
#   cd netbox
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
#   PGHOST=127.0.0.1 PGPORT=5432 PGUSER=netbox PGPASSWORD=netbox \
#   PGDATABASE=netbox ./db/assert-identities.sh
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
export PGUSER="${PGUSER:-${POSTGRES_USER:-netbox}}"
export PGDATABASE="${PGDATABASE:-${POSTGRES_DB:-netbox}}"

PSQL=(psql -v ON_ERROR_STOP=1 -qtAX)
fail=0

note() { printf '  %s\n' "$*"; }
bad()  { printf '  FAIL: %s\n' "$*"; fail=1; }
q()    { "${PSQL[@]}" -c "$1"; }
has_table() {
  [ "$(q "SELECT count(*) FROM information_schema.tables
          WHERE table_schema='public' AND table_name='$1';")" -eq 1 ]
}

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
         OR table_name LIKE 'account_%'
         OR table_name LIKE 'auth%'
         OR table_name LIKE 'users_%'
         OR table_name IN ('django_admin_log',
                           'core_datasource',
                           'extras_webhook','extras_eventrule','extras_script'))
  ORDER BY table_name;")

note "credential-shaped tables discovered: ${#candidates[@]}"

# ── 2. Tables allowed to be non-empty, with their exact expected counts ────
#
# Anything discovered above and NOT named here must be empty.
declare -A EXPECTED=(
  # THREE demo identities and no others.
  #
  # Unlike Paperless — which ships `AnonymousUser` and `consumer` on a pristine
  # install — NetBox creates no stock accounts, so the expected count is the
  # roster size with nothing added. If this ever reads 4, a fourth account
  # exists that the demo does not document.
  [users_user]=3
  [users_userconfig]=3                         # NetBox auto-creates one per user
  [frisian_mcp_tokens_frisianmcptoken]=3
  [frisian_mcp_oauth_oauthclient]=1            # the published browser client
  [frisian_mcp_oauth_oauthaccesstoken]=0
  [frisian_mcp_oauth_oauthauthorizeconsent]=0

  # NetBox's OWN API tokens. The demo authenticates through frisian-mcp tokens
  # only; a users_token row would be a second, undocumented way in — and one
  # that bypasses the MCP gateway entirely to reach the REST API directly.
  [users_token]=0

  # This roster binds permissions to USERS, not groups. A populated group table
  # means a grant path nothing here inspects.
  [auth_group]=0
  [auth_group_permissions]=0
  [users_group]=0
  [users_group_permissions]=0
  [users_group_object_permissions]=0
  [users_user_groups]=0

  # NetBox grants via ObjectPermission (section 6 onward), not this M2M. It is
  # asserted empty rather than ignored: a row here would be a grant on a second
  # path, invisible to every other check in this file.
  [users_user_user_permissions]=0

  # Three ObjectPermissions — view for each scoped identity, plus one write.
  # demo-admin is a superuser and holds none.
  [users_objectpermission]=3
  [users_user_object_permissions]=3

  # NetBox 4.6 ships an ownership model. Unused by this demo.
  [users_owner]=0
  [users_owner_users]=0
  [users_owner_user_groups]=0
  [users_ownergroup]=0

  # A session in the artifact would be a live, transferable login shipped
  # inside a published image.
  #
  # ⚠️ THIS IS ALSO WHY THIS SCRIPT RUNS AGAINST A FRESHLY BOOTED STACK.
  # Anything that logs in creates one, so running this after the acceptance
  # checklist — which drives a real UI login — reports a session that is not in
  # the artifact at all. Same for the change log in section 11. `docker compose
  # restart` resets both, because the estate is restored on every start.
  [django_session]=0
  [django_admin_log]=0

  # The carved-out resources. The route deny_list keeps them off the scoped
  # doors; shipping zero instances means there is nothing to reach even on the
  # admin door. See the header of seed/build_estate.py.
  [extras_webhook]=0
  [extras_eventrule]=0
  [extras_script]=0
  [core_datasource]=0
)

# Row counts that legitimately move with the NetBox version — they track how
# many models exist, not how many grants were made. Asserted as "non-empty"
# rather than magic numbers that would rot; the SHAPE of the grants is checked
# by name in sections 6-9.
NONEMPTY_OK=(auth_permission users_objectpermission_object_types)

in_list() { local n="$1"; shift; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

for t in "${candidates[@]}"; do
  n=$(q "SELECT count(*) FROM public.\"${t}\";")
  if [ -n "${EXPECTED[$t]+set}" ]; then
    want="${EXPECTED[$t]}"
    if [ "$n" -eq "$want" ]; then note "ok    ${t} = ${n}"
    else bad "${t} = ${n}, expected exactly ${want}"; fi
  elif in_list "$t" "${NONEMPTY_OK[@]}"; then
    if [ "$n" -gt 0 ]; then note "ok    ${t} = ${n} (non-empty as expected)"
    else bad "${t} is empty; the grants cover no models"; fi
  else
    if [ "$n" -eq 0 ]; then note "ok    ${t} = 0"
    else bad "${t} = ${n}; credential-shaped, populated, and NOT expected"; fi
  fi
done

# ── 3. The identities are the RIGHT ones, not merely the right count ───────
#
# Three rows in users_user is satisfied by three wrong users. Name them.
ROSTER_USERS="demo-admin,demo-netops,demo-readonly"
actual=$(q "SELECT string_agg(username, ',' ORDER BY username) FROM users_user;")
[ "$actual" = "$ROSTER_USERS" ] && note "ok    usernames = ${actual}" \
                                || bad "usernames = '${actual}', expected '${ROSTER_USERS}'"

# ── 4. The build-only identity must never reach the artifact ───────────────
n=$(q "SELECT count(*) FROM users_user WHERE username = 'demo-builder';")
[ "$n" -eq 0 ] && note "ok    demo-builder absent" \
               || bad "demo-builder is PRESENT — it must be deleted before the dump"

# ── 5. Exactly one superuser, and it is demo-admin ─────────────────────────
supers=$(q "SELECT coalesce(string_agg(username, ',' ORDER BY username), '') FROM users_user WHERE is_superuser;")
[ "$supers" = "demo-admin" ] && note "ok    superusers = demo-admin" \
                             || bad "superusers = '${supers}', expected exactly 'demo-admin'"

# Every identity must be usable. An inactive account fails authentication with
# the same 401 as a wrong token, which reads to a viewer as a broken demo.
n=$(q "SELECT count(*) FROM users_user WHERE NOT is_active;")
[ "$n" -eq 0 ] && note "ok    all three accounts are active" \
               || bad "${n} account(s) are inactive"

# ── 6. Tiers are what the roster says ──────────────────────────────────────
tiers=$(q "SELECT string_agg(name || '=' || permission, ',' ORDER BY name)
           FROM frisian_mcp_tokens_frisianmcptoken;")
want_tiers="demo-admin=admin,demo-netops=read_write,demo-readonly=read"
[ "$tiers" = "$want_tiers" ] && note "ok    tiers = ${tiers}" \
                             || bad "tiers = '${tiers}', expected '${want_tiers}'"

# Every token must be live. An inactive one is a 401 that looks like a bad
# token, and the README prints all three as working.
n=$(q "SELECT count(*) FROM frisian_mcp_tokens_frisianmcptoken WHERE NOT is_active;")
[ "$n" -eq 0 ] && note "ok    all three tokens are active" \
               || bad "${n} token(s) are inactive"

# ── 7. demo-netops' write grant must stay NARROWER than its door ───────────
#
# THIS IS THE DEMO. Its door permits the write tier across eight dispatch
# groups; this identity can write in two. If someone "fixes" a refusal by
# widening the grant, the demonstration quietly stops demonstrating anything —
# so it is asserted by app label, not by count.
writes=$(q "
  SELECT coalesce(string_agg(DISTINCT ct.app_label, ',' ORDER BY ct.app_label), '')
  FROM users_objectpermission p
  JOIN users_user_object_permissions uo ON uo.objectpermission_id = p.id
  JOIN users_user u ON u.id = uo.user_id
  JOIN users_objectpermission_object_types t ON t.objectpermission_id = p.id
  JOIN django_content_type ct ON ct.id = t.contenttype_id
  WHERE u.username = 'demo-netops'
    AND ('add' = ANY(p.actions) OR 'change' = ANY(p.actions) OR 'delete' = ANY(p.actions));")
want_writes="dcim,ipam"
[ "$writes" = "$want_writes" ] && note "ok    demo-netops writes ${writes} only" \
                               || bad "demo-netops write apps = '${writes}', expected '${want_writes}'"

# The write grant is add+change with NO delete. That is deliberate: a demo that
# hands out destroy on the estate it is demonstrating gets emptied by the first
# curious visitor. It is also visible in the tool surface — `destroy` and
# `bulk_destroy` are absent from dcim for this identity while `create` and
# `update` are present, which is a sharper illustration of principal filtering
# than the door ceiling alone gives.
acts=$(q "SELECT coalesce(string_agg(DISTINCT a, ',' ORDER BY a), '')
          FROM users_objectpermission p
          JOIN users_user_object_permissions uo ON uo.objectpermission_id = p.id
          JOIN users_user u ON u.id = uo.user_id
          CROSS JOIN LATERAL unnest(p.actions) AS a
          WHERE u.username = 'demo-netops';")
want_acts="add,change,view"
[ "$acts" = "$want_acts" ] && note "ok    demo-netops actions = ${acts} (no delete)" \
                           || bad "demo-netops actions = '${acts}', expected '${want_acts}'"

# ── 8. demo-readonly must hold NO write action at all ──────────────────────
n=$(q "
  SELECT count(*)
  FROM users_objectpermission p
  JOIN users_user_object_permissions uo ON uo.objectpermission_id = p.id
  JOIN users_user u ON u.id = uo.user_id
  WHERE u.username = 'demo-readonly'
    AND ('add' = ANY(p.actions) OR 'change' = ANY(p.actions) OR 'delete' = ANY(p.actions));")
[ "$n" -eq 0 ] && note "ok    demo-readonly holds view actions only" \
               || bad "demo-readonly holds ${n} grant(s) carrying a write action"

# Every ObjectPermission must be enabled. A disabled row grants nothing, so a
# demo whose write proof silently stopped working would still pass sections 7
# and 8 — they read the actions array, not whether the row is live.
n=$(q "SELECT count(*) FROM users_objectpermission WHERE NOT enabled;")
[ "$n" -eq 0 ] && note "ok    all object permissions are enabled" \
               || bad "${n} object permission(s) are disabled"

# ── 9. Neither scoped identity may name the carved-out models ──────────────
#
# The route deny_list is one control; this is the independent second one. A
# grant on Webhook or EventRule would mean the two layers disagree, and the
# only reason they currently agree is that someone kept them parallel.
named=$(q "
  SELECT coalesce(string_agg(DISTINCT ct.app_label || '.' || ct.model, ','), '')
  FROM users_objectpermission p
  JOIN users_user_object_permissions uo ON uo.objectpermission_id = p.id
  JOIN users_user u ON u.id = uo.user_id
  JOIN users_objectpermission_object_types t ON t.objectpermission_id = p.id
  JOIN django_content_type ct ON ct.id = t.contenttype_id
  WHERE u.username IN ('demo-readonly','demo-netops')
    AND (ct.app_label, ct.model) IN
        (VALUES ('extras','webhook'), ('extras','eventrule'),
                ('extras','script'),  ('extras','exporttemplate'),
                ('extras','configtemplate'), ('core','datasource'),
                ('users','token'),    ('users','user'));")
[ -z "$named" ] && note "ok    no scoped grant names a carved-out model" \
                || bad "scoped grant(s) name carved-out model(s): ${named}"

# ── 10. The estate is actually there ───────────────────────────────────────
#
# An identity roster is perfect and useless against an empty database, and an
# empty database is exactly what a partially failed seed produces. This is the
# cheapest possible check that the artifact carries a demo.
declare -A ESTATE=(
  [dcim_site]=2
  [dcim_device]=8
  [dcim_interface]=32
  [ipam_prefix]=4
  [circuits_circuit]=2
)
for t in "${!ESTATE[@]}"; do
  n=$(q "SELECT count(*) FROM public.\"${t}\";")
  [ "$n" -eq "${ESTATE[$t]}" ] && note "ok    ${t} = ${n}" \
                               || bad "${t} = ${n}, expected ${ESTATE[$t]}"
done

# Every device must be sited and typed. A device missing either is what a
# half-completed build_estate.py leaves behind, and it reads as real data.
n=$(q "SELECT count(*) FROM dcim_device WHERE site_id IS NULL OR device_type_id IS NULL OR role_id IS NULL;")
[ "$n" -eq 0 ] && note "ok    every device has a site, type and role" \
               || bad "${n} device(s) are incomplete; build_estate.py did not finish"

# The write proof creates DC3-WriteProof and a 10.3.0.0/16 prefix. Neither
# belongs in the artifact — if they are here, an acceptance run was dumped.
n=$(q "SELECT count(*) FROM dcim_site WHERE name LIKE '%WriteProof%' OR name LIKE '%Breach%';")
[ "$n" -eq 0 ] && note "ok    no acceptance-test residue in the estate" \
               || bad "${n} acceptance-test object(s) present — this dump was taken after a test run"

# ── 11. The change log starts empty ────────────────────────────────────────
#
# Building the estate produces an ObjectChange for every save. That is a
# build-time trail, not part of the demo — and it names demo-builder, which is
# supposed to have left no trace.
if has_table core_objectchange; then
  n=$(q "SELECT count(*) FROM core_objectchange;")
  [ "$n" -eq 0 ] && note "ok    change log is empty" \
                 || bad "change log carries ${n} record(s).
            If this ran after the acceptance checklist, those are ITS writes,
            not the artifact's — see the django_session note in section 2.
            \`docker compose restart\` resets the estate; re-run against that."
fi

echo
if [ "$fail" -eq 0 ]; then echo "PASS — provisioned identity set and estate are exactly as specified."; exit 0
else echo "FAIL — see above."; exit 1; fi
