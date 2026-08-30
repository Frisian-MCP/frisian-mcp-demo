"""
Provision the frisian-mcp NetBox demo identities.

Run inside the application container:

    /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py shell < db/provision_identities.py

Idempotent — safe to re-run. The seed re-runs it; a wipe drops the database, so
it MUST be re-run against any freshly initialised instance.

WHAT THIS DEMONSTRATES
----------------------
The same server showing a different `tools/list` to different agents. Three
identities, three doors, three tier ceilings — and, deliberately, one identity
whose NetBox permissions are NARROWER than the door it connects through.

    demo-readonly   read        api/mcp/read-only    view on the scoped estate
    demo-netops     read_write  api/mcp/read-write   view on all; write dcim+ipam ONLY
    demo-admin      admin       api/mcp/ops          superuser

`demo-netops` is the interesting one. Its door permits the write tier across
eight resource groups; its ObjectPermissions permit writes to two. The door's
ceiling and the principal's grants are INDEPENDENT controls, and you can only
tell them apart by watching an identity be refused something its door plainly
allows. A refusal there is the feature, not a bug.

WHY OBJECTPERMISSION AND NOT DJANGO MODEL PERMISSIONS
------------------------------------------------------
NetBox resolves `user.has_perm()` through its own `ObjectPermission` model, the
same one Nautobot forked. Django's `user_permissions` are not the authority
here, so granting those would produce an identity that looks provisioned and is
refused everything — the discovery surface would be empty and nothing would say
why.

Every identity below earns its capabilities from a real ObjectPermission, which
is what keeps FRISIAN_MCP_PERMISSION_AWARE_DISCOVERY meaning what it says.

TOKENS ARE FIXED, PUBLISHED CONSTANTS
-------------------------------------
Frisian tokens are stored as HMAC-SHA256(raw, key) where the key is
FRISIAN_MCP_HMAC_KEY falling back to SECRET_KEY. The model auto-generates a
random raw value on first save *only when* `token` is unset — so this script
computes the digest itself from a fixed raw value, and the demo tokens are
reproducible across every build.

If FRISIAN_MCP_HMAC_KEY is not the demo constant when this runs, every token
minted here is unverifiable in the shipped image, silently. The script refuses
to run in that case rather than producing dead tokens.
"""

import os
import sys

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.contenttypes.models import ContentType

from frisian_mcp.contrib.oauth.models import OAuthClient, _hmac_secret
from frisian_mcp.contrib.tokens.models import FrisianMcpToken, _hmac_token
from users.models import ObjectPermission

User = get_user_model()

DEMO_HMAC_KEY = "frisian-mcp-demo-public-hmac-key-do-not-reuse"

# Published demo password. The web UI is part of the demo; these accounts are
# meant to be logged into. Deliberately not a secret and deliberately obvious.
DEMO_PASSWORD = "frisian-demo-public-password"  # noqa: S105

# Fixed raw Bearer tokens, documented in netbox/README.md and
# common/mcp-clients/. The same three strings the Nautobot host uses: an
# identity that means the same thing on both surfaces should not need a
# different line in a client config, and these two estates are the same domain.
TOKENS = {
    "demo-readonly": "frisian-demo-readonly-token-public-do-not-reuse",  # noqa: S106
    "demo-netops": "frisian-demo-netops-token-public-do-not-reuse",  # noqa: S106
    "demo-admin": "frisian-demo-admin-token-public-do-not-reuse",  # noqa: S106
    "demo-builder": "frisian-demo-builder-token-public-do-not-reuse",  # noqa: S106
}

OAUTH_CLIENT_NAME = "frisian-demo-browser-client"
OAUTH_CLIENT_ID = "frisian-demo-public-client-id"
OAUTH_CLIENT_SECRET = "frisian-demo-public-client-secret-do-not-reuse"  # noqa: S105

# Exact-match is required, so these are literal, not patterns. The loopback
# entries are this stack's own default binding (port 8083 — the other demo
# hosts own 8080, 8081 and 8082, and all four are meant to run at once).
OAUTH_REDIRECT_URIS = [
    "https://claude.ai/api/mcp/auth_callback",
    "http://localhost:8083/oauth/callback",
    "http://127.0.0.1:8083/oauth/callback",
]

# Browser/native flow only. Restricting this stops the published client and
# secret from being usable as a service-to-service credential via
# client_credentials, which would hand anyone who reads the README a token
# without the consent screen in the way.
OAUTH_GRANT_TYPES = ["authorization_code"]

# ---------------------------------------------------------------------------
# Scope definition — MIRRORS FRISIAN_MCP_ROUTES in config/frisian_mcp.py.
#
# Two layers, one answer: the MCP route layer decides what a door exposes, the
# NetBox permission layer decides what a principal may touch. When they
# disagree the stricter wins — but they should not disagree, so this list is
# kept deliberately parallel to `_SCOPED_ALLOW` / `_SCOPED_DENY` there.
# ---------------------------------------------------------------------------
SCOPED_APP_LABELS = [
    "dcim",
    "ipam",
    "circuits",
    "tenancy",
    "virtualization",
    "vpn",
    "wireless",
    "extras",
]

WRITABLE_APP_LABELS = ["dcim", "ipam"]

# Never granted to any scoped identity, at any tier.
#
# The first entry is the audit trail. The rest are the code-execution and
# outbound-request surface: a Webhook is an arbitrary outbound POST whose
# target an attacker chooses, an ExportTemplate and a ConfigTemplate are both
# server-rendered Jinja2, a Script is arbitrary Python, and an EventRule binds
# any of them to a trigger. They mirror the route deny_list exactly.
#
# The last block is accounts, tokens and Django internals, which are never on a
# scoped route.
EXCLUDED_MODELS = {
    ("extras", "objectchange"),
    ("extras", "webhook"),
    ("extras", "eventrule"),
    ("extras", "exporttemplate"),
    ("extras", "configtemplate"),
    ("extras", "script"),
    ("extras", "scriptmodule"),
    ("users", "user"),
    ("users", "token"),
    ("users", "objectpermission"),
    ("auth", "group"),
    ("auth", "permission"),
    ("contenttypes", "contenttype"),
    ("sessions", "session"),
    ("admin", "logentry"),
    ("core", "datasource"),
    ("core", "datafile"),
}

# Viewable but never writable by a scoped identity. A ConfigContext is JSON
# merged into device configuration rendering; a JournalEntry is free text on
# any object. Both are denied on the READ-WRITE door at the route layer too —
# two independent controls saying the same thing.
NEVER_WRITABLE_MODELS = {
    ("extras", "configcontext"),
    ("extras", "journalentry"),
}


def scoped_content_types(*, app_labels, exclude):
    """Return installed ContentTypes for *app_labels*, minus *exclude*."""
    cts = ContentType.objects.filter(app_label__in=app_labels)
    return [ct for ct in cts if (ct.app_label, ct.model) not in exclude]


def report_missing_apps():
    """Warn about scoped apps with no installed content types."""
    installed = set(ContentType.objects.values_list("app_label", flat=True))
    missing = [label for label in SCOPED_APP_LABELS if label not in installed]
    if missing:
        print(f"  ! scoped apps with no installed content types: {', '.join(missing)}")
        print("    (a dispatch group naming an uninstalled surface is skipped, not fatal)")


def upsert_user(username, *, is_superuser=False):
    """Create or update a demo user. Returns (user, created)."""
    user, created = User.objects.get_or_create(username=username)
    user.is_active = True
    # DO NOT set is_staff here. The plugin wrapper installs it as a READ-ONLY
    # property deriving from is_superuser:
    #
    #     NetBoxUser.is_staff = property(lambda self: self.is_superuser)
    #
    # frisian-mcp's Django-admin views expect the attribute to exist, and
    # NetBox's User model has no such field. Assigning to it raises
    # `AttributeError: property '<lambda>' of 'User' object has no setter`,
    # which names neither the wrapper nor the reason. Setting is_superuser is
    # already sufficient — is_staff follows from it by construction.
    user.is_superuser = is_superuser
    user.set_password(DEMO_PASSWORD)
    user.save()
    return user, created


def upsert_permission(name, user, actions, content_types):
    """Create or update an ObjectPermission bound to exactly *user*."""
    # `actions` is NOT NULL, so it must be supplied in the INSERT itself —
    # get_or_create(name=...) alone inserts a NULL and fails the constraint.
    perm, _ = ObjectPermission.objects.get_or_create(
        name=name,
        defaults={"actions": list(actions), "enabled": True},
    )
    perm.enabled = True
    perm.actions = list(actions)
    perm.save()
    # set() rather than add() — a re-run must not accumulate stale grants, and
    # a narrowed scope must actually narrow.
    perm.object_types.set(content_types)
    perm.users.set([user])
    perm.groups.set([])
    return perm


def upsert_token(username, user, tier):
    """Create or update the fixed demo token for *user* at *tier*."""
    raw = TOKENS[username]
    token, created = FrisianMcpToken.objects.get_or_create(
        token=_hmac_token(raw),
        defaults={"name": username, "permission": tier, "user": user},
    )
    if not created:
        token.name = username
        token.permission = tier
        token.user = user
        token.is_active = True
        token.save()
    return token, raw


def upsert_oauth_client(user):
    """Create or update the single published demo OAuth client.

    ONE client, at `read` tier. The door is chosen by the URL a user configures;
    the tier is fixed at issuance from the client, so per-door clients would
    mean per-door tiers — and a browser walk-up landing on a read_write client
    is exactly what FRISIAN_MCP_OAUTH_PKCE_DEFAULT_PERMISSION="read" exists to
    prevent.

    `user` is set because under permission-aware discovery the client's user FK
    is the principal whose permissions decide what the caller SEES. Left blank
    it falls back to FRISIAN_MCP_OAUTH_SERVICE_USER, which this config does not
    set — so a browser caller would authenticate and then see an empty
    tools/list.
    """
    client, created = OAuthClient.objects.get_or_create(
        client_id=OAUTH_CLIENT_ID,
        defaults={
            "client_secret": _hmac_secret(OAUTH_CLIENT_SECRET),
            "name": OAUTH_CLIENT_NAME,
            "permission": "read",
            "user": user,
            "redirect_uris": list(OAUTH_REDIRECT_URIS),
            "grant_types": list(OAUTH_GRANT_TYPES),
        },
    )
    if not created:
        client.client_secret = _hmac_secret(OAUTH_CLIENT_SECRET)
        client.name = OAUTH_CLIENT_NAME
        client.permission = "read"
        client.user = user
        client.redirect_uris = list(OAUTH_REDIRECT_URIS)
        client.grant_types = list(OAUTH_GRANT_TYPES)
        client.is_active = True
        client.save()
    return client


def delete_builder():
    """Remove the build-only identity and everything hanging off it."""
    removed = []
    for perm_name in ("demo-builder-view", "demo-builder-write"):
        n, _ = ObjectPermission.objects.filter(name=perm_name).delete()
        if n:
            removed.append(perm_name)
    n, _ = FrisianMcpToken.objects.filter(name="demo-builder").delete()
    if n:
        removed.append("token")
    n, _ = User.objects.filter(username="demo-builder").delete()
    if n:
        removed.append("user")
    return removed


def main():
    """Provision every demo identity. Idempotent."""
    active_key = getattr(settings, "FRISIAN_MCP_HMAC_KEY", "") or ""
    if active_key != DEMO_HMAC_KEY:
        print("REFUSING TO PROVISION.")
        print(f"  FRISIAN_MCP_HMAC_KEY is {active_key!r}, expected the demo constant.")
        print("  Tokens minted under a different key are unverifiable in the shipped")
        print("  image, and the failure is silent. Fix the key, then re-run.")
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
    # tier on eight groups; this identity can write two.
    user, _ = upsert_user("demo-netops")
    upsert_permission("demo-netops-view", user, ["view"], view_cts)
    upsert_permission("demo-netops-write", user, ["add", "change"], write_cts)
    _, raw = upsert_token("demo-netops", user, "read_write")
    print(
        f"  demo-netops     tier=read_write  view={len(view_cts)} "
        f"write={len(write_cts)}  token={raw}"
    )

    # ── demo-admin ─────────────────────────────────────────────────────────
    #
    # Superuser, so it bypasses ObjectPermission entirely. That is the right
    # contrast for a door whose allow_list is ["*"] — but it means this
    # identity demonstrates the TIER CEILING, not the permission model. Say so
    # in the docs rather than letting a reader conclude admin is scoped.
    user, _ = upsert_user("demo-admin", is_superuser=True)
    _, raw = upsert_token("demo-admin", user, "admin")
    print(f"  demo-admin      tier=admin       superuser  token={raw}")

    # ── demo-builder — OPT-IN, and it must not survive to the golden dump ──
    #
    # The estate build needs an identity that can create reference data no demo
    # identity should be able to write. Widening demo-netops to cover that
    # would destroy the very gap the demo exists to show.
    #
    # Deliberately SCOPED, not superuser: a superuser builder cannot be
    # refused, so it would silently paper over a missing capability the build
    # run exists to measure.
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
        print("    ! demo-builder must be DELETED before the golden dump.")
    else:
        # Declarative, not merely skipped: with the flag off this script's job
        # is to make demo-builder ABSENT, so a re-run after the build cleans up
        # rather than leaving whatever the last run happened to create.
        removed = delete_builder()
        if removed:
            print(f"  demo-builder    DELETED ({', '.join(removed)})")
        else:
            print("  demo-builder    absent (set DEMO_PROVISION_BUILDER=1 for the build)")

    ro = User.objects.get(username="demo-readonly")
    upsert_oauth_client(ro)
    print(f"  oauth client    tier=read  user=demo-readonly  client_id={OAUTH_CLIENT_ID}")

    print("Done.")


main()
