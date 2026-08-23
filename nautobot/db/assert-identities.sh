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
#
# The OAuth client count is DECLARED, not guessed. What ships is the client
# registered during the build (B4), so the count is not knowable when this
# script is written — the operator states it at assert time and the assertion
# holds them to it. Default 0 so a pre-B4 run is meaningful.
: "${DEMO_EXPECTED_OAUTH_CLIENTS:=0}"

declare -A EXPECTED=(
  [auth_user]=3                              # demo-readonly, demo-netops, demo-admin
  [frisian_mcp_tokens_frisianmcptoken]=3
  [users_objectpermission]=6                 # 3 STOCK Nautobot + 3 roster (see STOCK_PERMS)
  [users_objectpermission_users]=3           # roster only; the stock three bind groups, not users
  [users_objectpermission_groups]=5          # STOCK Nautobot approval-workflow defaults
  [frisian_mcp_oauth_oauthclient]="${DEMO_EXPECTED_OAUTH_CLIENTS}"
  [frisian_mcp_oauth_oauthaccesstoken]=0
  [frisian_mcp_oauth_oauthauthorizeconsent]=0
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

# ── 2b. OAuth: ship the durable half, never the perishable half ────────────
#
# The OAuth CLIENT is durable — it has no expiry, and it is what lets a viewer
# complete authorize and mint their own fresh token. It ships.
#
# An ACCESS TOKEN is not. `OAuthAccessToken.expires_at` is stamped at mint
# time against a 3600s package default, and for a published image mint time is
# BUILD time — so a baked access token ships already dead and reads to a user
# as "the demo is broken". Assert it is absent rather than shipping a
# credential with a clock on it.
#
# The CONSENT row is asserted absent as a FORWARD GUARD, and the honest reason
# matters here. It cannot currently fast-path anything: AuthorizeView gates on
# `auto_approve and has_prior_consent(...)`, and this config sets
# AUTO_APPROVE=False, so the `and` short-circuits and the consent screen always
# renders. (Anonymous requests cannot store consent rows either.) The reason to
# assert it is that AUTO_APPROVE=True is a one-line change someone will reach
# for to smooth the demo — and on that day the artifact should already be
# clean. Minimal-artifact hygiene that hardens a future config change.
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

# ── 8. Grants: the STOCK baseline is named, and ours are user-bound ────────
#
# CORRECTED TWICE, so both corrections are recorded.
#
# (1) An earlier version claimed an ObjectPermission bound to no user "grants
#     everyone". Wrong: nautobot/core/authentication.py resolves grants with
#         Q(users=user_obj) | Q(groups__user=user_obj), enabled=True
#     so a permission bound to neither grants NOBODY — dead weight, not a hole.
#
# (2) The replacement said "no group bindings, nothing unbound". That can NEVER
#     pass, because stock Nautobot 3.2.3 ships THREE enabled ObjectPermissions
#     of its own, group-bound with no members, contributing 5 group rows.
#     Verified on a pristine install with zero users and zero provisioning.
#
# The fix is a NAMED baseline rather than a looser count. Naming the three
# means a future Nautobot adding a fourth fails loudly instead of widening the
# allowance silently — the same property the "table fifteen" sweep exists for.
#
# They are not a hole today (group-bound, no members), but the instinct behind
# the check still applies: anyone later added to one of these groups silently
# acquires approval-workflow write access.
STOCK_PERMS="nautobot-default-scheduledjobs-approver-permissions,nautobot-default-scheduledjobs-architect-permissions,nautobot-default-scheduledjobs-operator-permissions"
ROSTER_PERMS="demo-netops-view,demo-netops-write,demo-readonly-view"

actual_perms=$(q "SELECT string_agg(name, ',' ORDER BY name) FROM users_objectpermission;")
want_perms=$(printf '%s\n%s\n' "${STOCK_PERMS//,/$'\n'}" "${ROSTER_PERMS//,/$'\n'}" | sort | paste -sd, -)
[ "$actual_perms" = "$want_perms" ] && note "ok    ObjectPermission names = stock(3) + roster(3)" \
                                    || bad "ObjectPermission names differ.
            got:  ${actual_perms}
            want: ${want_perms}"

# Every NON-STOCK grant must be bound to a named user. The stock three are
# excluded by name, not by count, so a new unbound grant still fails.
n=$(q "SELECT count(*) FROM users_objectpermission op
       WHERE op.enabled
         AND op.name NOT IN ('nautobot-default-scheduledjobs-approver-permissions',
                             'nautobot-default-scheduledjobs-architect-permissions',
                             'nautobot-default-scheduledjobs-operator-permissions')
         AND op.id NOT IN (SELECT objectpermission_id FROM users_objectpermission_users);")
[ "$n" -eq 0 ] && note "ok    every non-stock grant is bound to a named user" \
               || bad "${n} non-stock ObjectPermission(s) bound to no user"

# No NON-STOCK group binding. A group grant widens later, without the
# permission itself being touched.
n=$(q "SELECT count(*) FROM users_objectpermission_groups g
       JOIN users_objectpermission op ON op.id = g.objectpermission_id
       WHERE op.name NOT IN ('nautobot-default-scheduledjobs-approver-permissions',
                             'nautobot-default-scheduledjobs-architect-permissions',
                             'nautobot-default-scheduledjobs-operator-permissions');")
[ "$n" -eq 0 ] && note "ok    no non-stock group bindings" \
               || bad "${n} non-stock group binding(s); this roster binds users only"

echo
if [ "$fail" -eq 0 ]; then echo "PASS — provisioned identity set is exactly as specified."; exit 0
else echo "FAIL — see above."; exit 1; fi
