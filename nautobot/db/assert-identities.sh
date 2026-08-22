#!/usr/bin/env bash
#
# B3 — assert the provisioned identity set, and NOTHING else.
#
# Renamed from assert-credentials-reset.sh by the 2026-08-22 scope change. The
# design is unchanged and the polarity is inverted: there is no inherited
# database to strip any more, so instead of asserting a known list of tables is
# empty, this asserts that exactly the expected identities exist and that every
# other credential-bearing table is empty.
#
# WHY IT IS SCHEMA-DRIVEN AND NOT A HARDCODED LIST
# ------------------------------------------------
# A hardcoded list is a check that expires silently the day the schema grows.
# Measured, not theorised: the inherited database carried 7 rows in
# `users_objectpermission` and 466 in `users_objectpermission_object_types`.
# An assertion naming only the first passes green with all 466 still present.
# So the sweep discovers tables by PATTERN and fails on anything credential-
# shaped that is populated and not explicitly expected. Table fifteen cannot
# arrive unnoticed.
#
# It is an INDEPENDENT control, not a re-run of provisioning: it must not
# import or call provision_identities.py. A check that trusts the thing it is
# checking is not a check.
#
# Per the D7/B5 ruling this runs against the ARTIFACT, not the database the
# artifact came from.
#
# Usage:
#   PGHOST=... PGUSER=nautobot PGDATABASE=nautobot ./assert-identities.sh
set -euo pipefail

# Uses associative arrays and mapfile — bash 4.0+. macOS ships bash 3.2, so say
# so rather than failing with a confusing syntax error two hundred lines down.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "::error::this script requires bash 4.0+ (found ${BASH_VERSION:-unknown})." >&2
  exit 1
fi

PSQL=(psql -v ON_ERROR_STOP=1 -qtAX)
fail=0

note() { printf '  %s\n' "$*"; }
bad()  { printf '  FAIL: %s\n' "$*"; fail=1; }

q() { "${PSQL[@]}" -c "$1"; }

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
         OR table_name IN ('auth_user','auth_user_groups','auth_user_user_permissions',
                           'django_admin_log')
         OR table_name LIKE 'users_objectpermission%'
         OR table_name LIKE 'social_auth_%')
  ORDER BY table_name;")

note "credential-shaped tables discovered: ${#candidates[@]}"

# ── 2. Tables allowed to be non-empty, with their exact expected counts ────
#
# Anything discovered above and NOT named here must be empty.
declare -A EXPECTED=(
  [auth_user]=3                              # demo-readonly, demo-netops, demo-admin
  [frisian_mcp_tokens_frisianmcptoken]=3
  [users_objectpermission]=3                 # readonly-view, netops-view, netops-write
  [users_objectpermission_users]=3
)
# Row count is not fixed for the object_types M2M — it tracks how many content
# types the scoped grants cover, which legitimately moves with the plugin set.
# Asserted as "non-empty" rather than a magic number that would rot.
NONEMPTY_OK=(users_objectpermission_object_types)

in_list() { local n="$1"; shift; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

for t in "${candidates[@]}"; do
  n=$(q "SELECT count(*) FROM public.\"${t}\";")
  if [ -n "${EXPECTED[$t]+set}" ]; then
    want="${EXPECTED[$t]}"
    if [ "$n" -eq "$want" ]; then note "ok    ${t} = ${n}"
    else bad "${t} = ${n}, expected exactly ${want}"; fi
  elif in_list "$t" "${NONEMPTY_OK[@]}"; then
    if [ "$n" -gt 0 ]; then note "ok    ${t} = ${n} (non-empty as expected)"
    else bad "${t} is empty; the scoped grants cover no content types"; fi
  else
    if [ "$n" -eq 0 ]; then note "ok    ${t} = 0"
    else bad "${t} = ${n}; credential-shaped, populated, and NOT expected"; fi
  fi
done

# ── 3. The identities are the RIGHT ones, not merely the right count ───────
#
# Three rows in auth_user is satisfied by three wrong users. Name them.
actual=$(q "SELECT string_agg(username, ',' ORDER BY username) FROM auth_user;")
want="demo-admin,demo-netops,demo-readonly"
[ "$actual" = "$want" ] && note "ok    usernames = ${actual}" \
                        || bad "usernames = '${actual}', expected '${want}'"

# ── 4. The build-only identity must never reach the artifact ───────────────
n=$(q "SELECT count(*) FROM auth_user WHERE username = 'demo-builder';")
[ "$n" -eq 0 ] && note "ok    demo-builder absent" \
               || bad "demo-builder is PRESENT — it must be deleted before the dump (B5)"

# ── 5. Exactly one superuser, and it is demo-admin ─────────────────────────
supers=$(q "SELECT coalesce(string_agg(username, ',' ORDER BY username), '') FROM auth_user WHERE is_superuser;")
[ "$supers" = "demo-admin" ] && note "ok    superusers = demo-admin" \
                             || bad "superusers = '${supers}', expected exactly 'demo-admin'"

# ── 6. Tiers are what the roster says ──────────────────────────────────────
tiers=$(q "SELECT string_agg(name || '=' || permission, ',' ORDER BY name)
           FROM frisian_mcp_tokens_frisianmcptoken;")
want_tiers="demo-admin=admin,demo-netops=read_write,demo-readonly=read"
[ "$tiers" = "$want_tiers" ] && note "ok    tiers = ${tiers}" \
                             || bad "tiers = '${tiers}', expected '${want_tiers}'"

# ── 7. demo-netops' write grant must stay NARROWER than its door ───────────
#
# This is the demo. If someone "fixes" a refusal by widening the grant, the
# demonstration quietly stops demonstrating anything — so it is asserted.
apps=$(q "SELECT coalesce(string_agg(DISTINCT ct.app_label, ',' ORDER BY ct.app_label), '')
          FROM users_objectpermission op
          JOIN users_objectpermission_object_types m ON m.objectpermission_id = op.id
          JOIN django_content_type ct ON ct.id = m.contenttype_id
          WHERE op.name = 'demo-netops-write';")
[ "$apps" = "dcim,ipam" ] && note "ok    demo-netops writes dcim,ipam only" \
                          || bad "demo-netops write apps = '${apps}', expected 'dcim,ipam'"

# ── 8. Every grant is bound to a named demo user, and to no group ──────────
#
# CORRECTED 2026-08-22. An earlier version of this check claimed an
# ObjectPermission bound to no user "grants everyone". That is wrong, and the
# source says so: nautobot/core/authentication.py resolves grants with
#     Q(users=user_obj) | Q(groups__user=user_obj), enabled=True
# so a permission bound to neither users nor groups grants NOBODY. It is dead
# weight, not a hole.
#
# What is worth asserting is the opposite direction. This roster binds every
# grant to one named user and uses no groups at all, because a group binding
# widens a grant to whoever is in the group later — silently, and without
# touching the permission. So: no group bindings, and nothing unbound.
n=$(q "SELECT count(*) FROM users_objectpermission op WHERE op.enabled
       AND op.id NOT IN (SELECT objectpermission_id FROM users_objectpermission_users);")
[ "$n" -eq 0 ] && note "ok    every enabled grant is bound to a user" \
               || bad "${n} enabled ObjectPermission(s) bound to no user — dead weight, or a group grant this roster does not use"

n=$(q "SELECT count(*) FROM users_objectpermission_groups;")
[ "$n" -eq 0 ] && note "ok    no group-bound grants" \
               || bad "${n} group binding(s); this roster binds users only, so a group grant widens it invisibly"

echo
if [ "$fail" -eq 0 ]; then echo "PASS — provisioned identity set is exactly as specified."; exit 0
else echo "FAIL — see above."; exit 1; fi
