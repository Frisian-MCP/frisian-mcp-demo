"""
Provision the frisian-mcp demo identities (B3).

Run inside the application container:

    nautobot-server shell < db/provision_identities.py

Idempotent — safe to re-run. CI re-runs it; a wipe drops the database, so it
MUST be re-run against any freshly initialised instance.

WHAT THIS DEMONSTRATES
----------------------
The same server showing a different `tools/list` to different agents. Three
identities, three doors, three tier ceilings — and, deliberately, one identity
whose Django permissions are NARROWER than the door it connects through.

    demo-readonly   read        mcp/read-only    view on the scoped estate
    demo-netops     read_write  mcp/read-write   view on all; write dcim+ipam ONLY
    demo-admin      admin       mcp/admin        superuser

`demo-netops` is the interesting one. Its door allows the write tier across all
thirteen scoped resources; its ObjectPermissions allow writes to two of them.
The door's tier ceiling and the principal's grants are INDEPENDENT controls,
and you can only tell them apart by watching an identity get refused something
its door plainly allows. A refusal here is the feature, not a bug.

WHY NOT `EXEMPT_VIEW_PERMISSIONS` (2026-07-13, learned the hard way)
--------------------------------------------------------------------
A global `EXEMPT_VIEW_PERMISSIONS = "*"` grants `view_<model>` to EVERY
authenticated principal, which silently destroys per-user scoping everywhere
else: a service account scoped to one app was observed receiving the entire
estate, because the exemption — not its ObjectPermission — was supplying the
capabilities. A global exemption and per-principal scoping are mutually
exclusive. Every identity below earns its capabilities from a real
ObjectPermission, so FRISIAN_MCP_PERMISSION_AWARE_DISCOVERY keeps meaning what
it says.

TOKENS ARE FIXED, PUBLISHED CONSTANTS
-------------------------------------
Frisian tokens are stored as HMAC-SHA256(raw, key) where the key is
FRISIAN_MCP_HMAC_KEY falling back to SECRET_KEY. The model auto-generates a
random raw value on first save *only when* `token` is unset — so this script
computes the digest itself from a fixed raw value, and the demo tokens are
reproducible across every build. They are published by design; the HMAC key
that covers them is published too. Nothing here is a secret.

If FRISIAN_MCP_HMAC_KEY is not the demo constant when this runs, every token
minted here is unverifiable in the shipped image, silently. The script refuses
to run in that case rather than producing dead tokens.
"""

import os
import sys

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.contenttypes.models import ContentType

from frisian_mcp.contrib.tokens.models import FrisianMcpToken, _hmac_token
from nautobot.users.models import ObjectPermission

User = get_user_model()

DEMO_HMAC_KEY = "frisian-mcp-demo-public-hmac-key-do-not-reuse"

# Published demo password. The UI is part of the demo; these accounts are meant
# to be logged into. Deliberately not a secret and deliberately obvious.
DEMO_PASSWORD = "frisian-demo-public-password"  # noqa: S105

# Fixed raw Bearer tokens. Documented in nautobot/README.md and
# common/mcp-clients/. Changing one invalidates every client config that ships
# with this repo.
TOKENS = {
    "demo-readonly": "frisian-demo-readonly-token-public-do-not-reuse",  # noqa: S106
    "demo-netops": "frisian-demo-netops-token-public-do-not-reuse",  # noqa: S106
    "demo-admin": "frisian-demo-admin-token-public-do-not-reuse",  # noqa: S106
    "demo-builder": "frisian-demo-builder-token-public-do-not-reuse",  # noqa: S106
}

# ---------------------------------------------------------------------------
# Scope definition — MIRRORS FRISIAN_MCP_ROUTES in config/nautobot_config.py.
#
# Two layers, one answer: the MCP route layer decides what a door exposes, the
# Nautobot permission layer decides what a principal may touch. When they
# disagree, the stricter wins — but they should not disagree, so this list is
# kept deliberately parallel to `_SCOPED_ALLOW` / `_SCOPED_DENY` there.
#
# App labels are resolved against INSTALLED ContentTypes at runtime rather than
# hardcoded, because plugin app labels differ from their MCP dispatch-group
# names and a group naming an uninstalled surface is skipped rather than fatal.
# ---------------------------------------------------------------------------
SCOPED_APP_LABELS = [
    "dcim",
    "ipam",
    "circuits",
    "tenancy",
    "virtualization",
    "wireless",
    "cloud",
    "extras",
    "nautobot_golden_config",
    "nautobot_dns_models",
    "nautobot_bgp_models",
    "nautobot_ssot",
]

WRITABLE_APP_LABELS = ["dcim", "ipam"]

# Never granted to any scoped identity, at any tier.
#
# The first block mirrors the route deny_list (secrets material + the object
# change log). The second is the S-1 ruling: resources whose custom @action
# methods are code execution or outbound request wearing a data model —
# GitRepository clones an arbitrary URL and can load Jobs from it, Webhook is
# an arbitrary outbound POST, ExportTemplate is server-rendered Jinja2.
# The third is the accounts and API-token surface, which is never on a scoped
# route. The fourth is Django internals with no MCP tool surface.
EXCLUDED_MODELS = {
    ("extras", "secret"),
    ("extras", "secretsgroup"),
    ("extras", "secretsgroupassociation"),
    ("extras", "objectchange"),
    ("extras", "gitrepository"),
    ("extras", "webhook"),
    ("extras", "externalintegration"),
    ("extras", "jobhook"),
    ("extras", "jobbutton"),
    ("extras", "scheduledjob"),
    ("extras", "exporttemplate"),
    ("extras", "fileproxy"),
    ("extras", "graphqlquery"),
    ("users", "user"),
    ("users", "objectpermission"),
    ("users", "token"),
    ("auth", "group"),
    ("auth", "permission"),
    ("contenttypes", "contenttype"),
    ("sessions", "session"),
    ("admin", "logentry"),
}

# `extras:job` is denied on the READ-WRITE door only (_RW_ONLY_DENY), because
# JobViewSetBase.run is a POST @action and a Nautobot Job is arbitrary Python.
# On the read-only door the route's `read` ceiling already excludes `run`
# without the deny_list doing anything, so the Jobs catalogue stays browsable
# there. It is therefore viewable but never writable.
NEVER_WRITABLE_MODELS = {
    ("extras", "job"),
    ("extras", "jobresult"),
    ("extras", "joblogentry"),
}


def scoped_content_types(*, app_labels, exclude):
    """Return installed ContentTypes for *app_labels*, minus *exclude*."""
    cts = ContentType.objects.filter(app_label__in=app_labels)
    return [ct for ct in cts if (ct.app_label, ct.model) not in exclude]


def report_missing_apps():
    """Warn about scoped apps with no installed ContentTypes."""
    installed = set(ContentType.objects.values_list("app_label", flat=True))
    missing = [label for label in SCOPED_APP_LABELS if label not in installed]
    if missing:
        print(f"  ! scoped apps with no installed content types: {', '.join(missing)}")
        print("    (a dispatch group naming an uninstalled surface is skipped, not fatal)")


def upsert_user(username, *, is_superuser=False):
    """Create or update a demo user. Returns (user, created)."""
    user, created = User.objects.get_or_create(username=username)
    user.is_active = True
    user.is_staff = is_superuser
    user.is_superuser = is_superuser
    user.set_password(DEMO_PASSWORD)
    user.save()
    return user, created


def upsert_permission(name, user, actions, content_types):
    """Create or update an ObjectPermission bound to exactly *user*."""
    perm, _ = ObjectPermission.objects.get_or_create(name=name)
    perm.enabled = True
    perm.actions = list(actions)
    perm.save()
    # set() rather than add() — a re-run must not accumulate stale grants.
    perm.object_types.set(content_types)
    perm.users.set([user])
    perm.groups.set([])
    return perm


def upsert_token(username, user, tier):
    """Create or update the fixed demo token for *user* at *tier*."""
    raw = TOKENS[username]
    digest = _hmac_token(raw)
    token, created = FrisianMcpToken.objects.get_or_create(
        token=digest,
        defaults={"name": username, "permission": tier, "user": user},
    )
    if not created:
        token.name = username
        token.permission = tier
        token.user = user
        token.is_active = True
        token.save()
    return token, raw


def main():
    """Provision every demo identity. Idempotent."""
    # ── Guard: minting under the wrong key produces silently dead tokens ────
    active_key = getattr(settings, "FRISIAN_MCP_HMAC_KEY", "") or ""
    if active_key != DEMO_HMAC_KEY:
        print("REFUSING TO PROVISION.")
        print(f"  FRISIAN_MCP_HMAC_KEY is {active_key!r}, expected the demo constant.")
        print("  Tokens minted under a different key are unverifiable in the shipped")
        print("  image, and the failure is silent (F1). Fix the key, then re-run.")
        sys.exit(1)

    print("Provisioning frisian-mcp demo identities")
    report_missing_apps()

    view_cts = scoped_content_types(app_labels=SCOPED_APP_LABELS, exclude=EXCLUDED_MODELS)
    write_cts = scoped_content_types(
        app_labels=WRITABLE_APP_LABELS,
        exclude=EXCLUDED_MODELS | NEVER_WRITABLE_MODELS,
    )
    print(f"  scoped view content types:  {len(view_cts)}")
    print(f"  scoped write content types: {len(write_cts)} (dcim + ipam)")

    # ── demo-readonly ──────────────────────────────────────────────────────
    user, _ = upsert_user("demo-readonly")
    upsert_permission("demo-readonly-view", user, ["view"], view_cts)
    _, raw = upsert_token("demo-readonly", user, "read")
    print(f"  demo-readonly   tier=read        view={len(view_cts)}  token={raw}")

    # ── demo-netops ────────────────────────────────────────────────────────
    #
    # TWO permissions, not one, and that is the demonstration: a wide view
    # grant and a deliberately narrow write grant. Its door allows the write
    # tier on all thirteen scoped resources; this identity can write two.
    user, _ = upsert_user("demo-netops")
    upsert_permission("demo-netops-view", user, ["view"], view_cts)
    upsert_permission("demo-netops-write", user, ["add", "change"], write_cts)
    _, raw = upsert_token("demo-netops", user, "read_write")
    print(f"  demo-netops     tier=read_write  view={len(view_cts)} write={len(write_cts)}  token={raw}")

    # ── demo-admin ─────────────────────────────────────────────────────────
    #
    # Superuser, so it bypasses ObjectPermission entirely. That is the correct
    # contrast for a door whose allow_list is ["*"] — but it means this
    # identity demonstrates the TIER CEILING, not the permission model. Say so
    # in the docs rather than letting a reader conclude admin is scoped.
    user, _ = upsert_user("demo-admin", is_superuser=True)
    _, raw = upsert_token("demo-admin", user, "admin")
    print(f"  demo-admin      tier=admin       superuser  token={raw}")

    # ── demo-builder — OPT-IN, and it must not survive to the golden dump ──
    #
    # B4 needs an identity that can create the reference data no demo identity
    # should be able to write (Statuses, Roles, Manufacturers, DeviceTypes,
    # Tenants, Circuits, DNS, BGP). Widening demo-netops to cover that would
    # destroy the very gap the demo exists to show, so this is separate and
    # temporary.
    #
    # Deliberately SCOPED, not superuser: a superuser builder cannot be
    # refused, so it would silently paper over a missing capability or an
    # array-param rejection that the build run exists to measure. A scoped
    # builder fails honestly.
    #
    # Off by default. B4 sets DEMO_PROVISION_BUILDER=1; B5 must confirm it is
    # gone before dumping.
    if os.environ.get("DEMO_PROVISION_BUILDER") == "1":
        builder_cts = scoped_content_types(
            app_labels=SCOPED_APP_LABELS,
            exclude=EXCLUDED_MODELS | NEVER_WRITABLE_MODELS,
        )
        user, _ = upsert_user("demo-builder")
        upsert_permission("demo-builder-view", user, ["view"], view_cts)
        upsert_permission(
            "demo-builder-write", user, ["add", "change", "delete"], builder_cts
        )
        _, raw = upsert_token("demo-builder", user, "read_write")
        print(f"  demo-builder    tier=read_write  BUILD-ONLY write={len(builder_cts)}  token={raw}")
        print("    ! demo-builder must be DELETED before the golden dump (B5).")
    else:
        print("  demo-builder    not provisioned (set DEMO_PROVISION_BUILDER=1 for B4)")

    print("Done.")


main()
