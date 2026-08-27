"""
Provision the frisian-mcp Paperless demo identities.

Run inside the application container:

    python3 manage.py shell < db/provision_identities.py

Idempotent — safe to re-run. The seed re-runs it; a wipe drops the database, so
it MUST be re-run against any freshly initialised instance.

WHAT THIS DEMONSTRATES
----------------------
The same server showing a different `tools/list` to different agents. Three
identities, three doors, three tier ceilings — and, deliberately, one identity
whose Django permissions are NARROWER than the door it connects through.

    demo-readonly   read        mcp/read-only   view on the scoped estate
    demo-editor     read_write  mcp/read-write  view on all; write documents + tags ONLY
    demo-admin      admin       mcp/ops         superuser

`demo-editor` is the interesting one. Its door permits the write tier across
five resource groups; its Django permissions permit writes to two models. The
door's tier ceiling and the principal's grants are INDEPENDENT controls, and
you can only tell them apart by watching an identity get refused something its
door plainly allows. A refusal there is the feature, not a bug.

WHY MODEL PERMISSIONS AND NOT A BLANKET EXEMPTION
-------------------------------------------------
Every identity below earns its capabilities from real Django permissions, so
FRISIAN_MCP_PERMISSION_AWARE_DISCOVERY keeps meaning what it says. Anything
that hands out capabilities globally — a permission adapter that returns True,
a group everyone is in — silently destroys per-principal scoping everywhere
else, and the failure looks like the package reporting the wrong surface when
in fact it is faithfully reporting the wrong capabilities.

Paperless layers django-guardian object permissions on top of Django's model
permissions. This script grants MODEL permissions only, which is the layer
`user.has_perm("documents.view_document")` consults and therefore the layer
permission-aware discovery reads. Guardian's per-object grants are left
untouched: the demo scopes by model, not by document.

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
from django.contrib.auth.models import Permission
from django.contrib.contenttypes.models import ContentType

from frisian_mcp.contrib.oauth.models import OAuthClient, _hmac_secret
from frisian_mcp.contrib.tokens.models import FrisianMcpToken, _hmac_token

User = get_user_model()

DEMO_HMAC_KEY = "frisian-mcp-demo-public-hmac-key-do-not-reuse"

# Published demo password. The web UI is part of the demo; these accounts are
# meant to be logged into. Deliberately not a secret and deliberately obvious.
DEMO_PASSWORD = "frisian-demo-public-password"  # noqa: S105

# Fixed raw Bearer tokens. Documented in paperless/README.md and
# common/mcp-clients/. Changing one invalidates every client config that ships
# with this repo.
#
# `readonly` and `admin` deliberately carry the SAME raw values as the Nautobot
# host's. The demos are meant to be brought up the same way, and an identity
# that means the same thing on both surfaces should not need a different line
# in a client config. `editor` differs from Nautobot's `netops` because the
# identity itself differs — the scoped writer is host-specific by nature.
TOKENS = {
    "demo-readonly": "frisian-demo-readonly-token-public-do-not-reuse",  # noqa: S106
    "demo-editor": "frisian-demo-editor-token-public-do-not-reuse",  # noqa: S106
    "demo-admin": "frisian-demo-admin-token-public-do-not-reuse",  # noqa: S106
    "demo-builder": "frisian-demo-builder-token-public-do-not-reuse",  # noqa: S106
}

# ---------------------------------------------------------------------------
# OAuth client — ONE, at `read` tier. Published, like everything else here.
#
# WHY ONE, AND WHY `read`. The door is chosen by the URL a user configures; the
# tier is fixed at issuance from the client. Per-door clients would therefore
# mean per-door tiers, and a browser walk-up landing on a read_write client is
# exactly what FRISIAN_MCP_OAUTH_PKCE_DEFAULT_PERMISSION="read" exists to
# prevent. Self-serve gets you read; elevated access stays provisioned static
# tokens.
#
# WHY `user` IS SET. Under FRISIAN_MCP_PERMISSION_AWARE_DISCOVERY the client's
# `user` FK is the principal whose permissions decide what the caller SEES.
# Left blank it falls back to FRISIAN_MCP_OAUTH_SERVICE_USER, which this config
# does not set — so a browser caller would authenticate successfully and then
# see an empty tools/list. Binding it to demo-readonly gives the OAuth path the
# same scoped surface as the read-only token, which is the point.
# ---------------------------------------------------------------------------
OAUTH_CLIENT_NAME = "frisian-demo-browser-client"
OAUTH_CLIENT_ID = "frisian-demo-public-client-id"
OAUTH_CLIENT_SECRET = "frisian-demo-public-client-secret-do-not-reuse"  # noqa: S105

# Exact-match is required, so these are literal, not patterns.
#
# The loopback entries are this stack's own default binding (port 8081 — the
# Nautobot host already owns 8080, and both demos are meant to be runnable at
# once). The claude.ai entry is the connector's published callback and is NOT
# verifiable from here; if a browser connect fails with an invalid redirect,
# this list is the first thing to correct.
OAUTH_REDIRECT_URIS = [
    "https://claude.ai/api/mcp/auth_callback",
    "http://localhost:8081/oauth/callback",
    "http://127.0.0.1:8081/oauth/callback",
]

# Browser/native flow only. Restricting this stops the published client and
# secret from being usable as a service-to-service credential via
# client_credentials, which would hand anyone who reads the README a token
# without the consent screen in the way.
OAUTH_GRANT_TYPES = ["authorization_code"]

# ---------------------------------------------------------------------------
# Scope definition — MIRRORS FRISIAN_MCP_ROUTES in
# config/paperless_frisian_mcp.py.
#
# Two layers, one answer: the MCP route layer decides what a door exposes, the
# Django permission layer decides what a principal may touch. When they
# disagree the stricter wins — but they should not disagree, so this list is
# kept deliberately parallel to `_SCOPED_ALLOW` / `_SCOPED_DENY` there.
#
# Content types are resolved against what is INSTALLED at runtime rather than
# hardcoded, so a Paperless release that adds or renames a model does not
# silently leave a grant pointing at nothing.
# ---------------------------------------------------------------------------
SCOPED_APP_LABELS = ["documents", "paperless_mail"]

# The scoped writer. Two models, and the narrowness is the demonstration: its
# door permits the write tier across five resource groups.
#
# Document and Tag rather than, say, Correspondent: retagging and retitling a
# document is the thing an agent is actually asked to do with a document
# archive, so the writes that DO work are useful ones rather than a token
# gesture. Everything else in the same dispatcher refuses.
WRITABLE_MODELS = [("documents", "document"), ("documents", "tag")]

# Never granted to any scoped identity, at any tier.
#
# MailAccount holds an IMAP password (and an OAuth refresh token for
# Gmail/Outlook accounts). It is credential storage wearing a configuration
# object, and it mirrors the route deny_list.
#
# ShareLink mints a URL that serves a document with NO authentication. Handing
# a scoped principal the ability to create one is handing it the ability to
# publish any document it can read to the open internet — which is a larger
# grant than "write access to documents" reads as. The `sharing` group is off
# both scoped doors for the same reason.
#
# The rest are accounts, Django internals and framework tables with no MCP tool
# surface a demo identity has any business naming.
EXCLUDED_MODELS = {
    ("paperless_mail", "mailaccount"),
    ("documents", "sharelink"),
    ("documents", "sharelinkbundle"),
}

# Viewable but never writable by a scoped identity.
#
# WorkflowAction carries webhook URLs, webhook bodies and headers, and email
# recipients, and the workflow engine fires them on document events. Creating
# one is server-side request forgery with a form in front of it. MailRule can
# be pointed at an arbitrary folder and given a delete action.
#
# On the READ door these are already unwritable — the route's `read` ceiling
# filters the action list — so this exclusion is what makes the READ-WRITE door
# behave the same way, from the permission side as well as the route side. Two
# independent controls saying the same thing.
NEVER_WRITABLE_MODELS = {
    ("documents", "workflow"),
    ("documents", "workflowtrigger"),
    ("documents", "workflowaction"),
    ("documents", "workflowrun"),
    ("paperless_mail", "mailrule"),
    ("paperless_mail", "processedmail"),
    ("documents", "paperlesstask"),
    ("documents", "log"),
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


def permissions_for(content_types, actions):
    """Return the Permission rows for *actions* over *content_types*."""
    codenames = [f"{action}_{ct.model}" for ct in content_types for action in actions]
    return list(
        Permission.objects.filter(
            content_type__in=content_types, codename__in=codenames
        )
    )


def upsert_user(username, *, is_superuser=False):
    """Create or update a demo user. Returns (user, created)."""
    user, created = User.objects.get_or_create(username=username)
    user.is_active = True
    user.is_staff = is_superuser
    user.is_superuser = is_superuser
    user.set_password(DEMO_PASSWORD)
    user.save()
    return user, created


def set_permissions(user, permissions):
    """Bind exactly *permissions* to *user*.

    `set()` rather than `add()` — a re-run must not accumulate stale grants,
    and a narrowed scope must actually narrow.

    Group membership is cleared for the same reason. A group grant widens later
    without the user's own permissions being touched, which is precisely the
    kind of drift this demo would fail to notice: the surface would quietly
    grow and still look provisioned.
    """
    user.user_permissions.set(permissions)
    user.groups.set([])
    user.save()


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


def upsert_oauth_client(user):
    """Create or update the single published demo OAuth client."""
    digest = _hmac_secret(OAUTH_CLIENT_SECRET)
    client, created = OAuthClient.objects.get_or_create(
        client_id=OAUTH_CLIENT_ID,
        defaults={
            "client_secret": digest,
            "name": OAUTH_CLIENT_NAME,
            "permission": "read",
            "user": user,
            "redirect_uris": list(OAUTH_REDIRECT_URIS),
            "grant_types": list(OAUTH_GRANT_TYPES),
        },
    )
    if not created:
        client.client_secret = digest
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
    n, _ = FrisianMcpToken.objects.filter(name="demo-builder").delete()
    if n:
        removed.append("token")
    n, _ = User.objects.filter(username="demo-builder").delete()
    if n:
        removed.append("user")
    return removed


def main():
    """Provision every demo identity. Idempotent."""
    # ── Guard: minting under the wrong key produces silently dead tokens ────
    active_key = getattr(settings, "FRISIAN_MCP_HMAC_KEY", "") or ""
    if active_key != DEMO_HMAC_KEY:
        print("REFUSING TO PROVISION.")
        print(f"  FRISIAN_MCP_HMAC_KEY is {active_key!r}, expected the demo constant.")
        print("  Tokens minted under a different key are unverifiable in the shipped")
        print("  image, and the failure is silent. Fix the key, then re-run.")
        sys.exit(1)

    print("Provisioning frisian-mcp demo identities")
    report_missing_apps()

    view_cts = scoped_content_types(
        app_labels=SCOPED_APP_LABELS, exclude=EXCLUDED_MODELS
    )
    write_cts = [ct for ct in view_cts if (ct.app_label, ct.model) in WRITABLE_MODELS]

    view_perms = permissions_for(view_cts, ["view"])
    write_perms = permissions_for(write_cts, ["add", "change"])

    print(f"  scoped view content types:  {len(view_cts)}")
    print(f"  scoped write content types: {len(write_cts)} (document + tag)")

    # ── demo-readonly ──────────────────────────────────────────────────────
    user, _ = upsert_user("demo-readonly")
    set_permissions(user, view_perms)
    _, raw = upsert_token("demo-readonly", user, "read")
    print(f"  demo-readonly   tier=read        view={len(view_perms)}  token={raw}")

    # ── demo-editor ────────────────────────────────────────────────────────
    #
    # A wide view grant and a deliberately narrow write grant. Its door permits
    # the write tier across five resource groups; this identity can write two
    # models. That gap is the demonstration — do not "fix" a refusal here by
    # widening the grant.
    user, _ = upsert_user("demo-editor")
    set_permissions(user, view_perms + write_perms)
    _, raw = upsert_token("demo-editor", user, "read_write")
    print(
        f"  demo-editor     tier=read_write  view={len(view_perms)} "
        f"write={len(write_perms)}  token={raw}"
    )

    # ── demo-admin ─────────────────────────────────────────────────────────
    #
    # Superuser, so it bypasses per-model permissions entirely. That is the
    # correct contrast for a door whose allow_list is ["*"] — but it means this
    # identity demonstrates the TIER CEILING, not the permission model. Say so
    # in the docs rather than letting a reader conclude admin is scoped.
    user, _ = upsert_user("demo-admin", is_superuser=True)
    _, raw = upsert_token("demo-admin", user, "admin")
    print(f"  demo-admin      tier=admin       superuser  token={raw}")

    # ── demo-builder — OPT-IN, and it must not survive to the golden dump ──
    #
    # The estate build needs an identity that can create the reference data no
    # demo identity should be able to write. Widening demo-editor to cover that
    # would destroy the very gap the demo exists to show, so this is separate
    # and temporary.
    #
    # Deliberately SCOPED, not superuser: a superuser builder cannot be
    # refused, so it would silently paper over a missing capability or a
    # rejected parameter shape that the build run exists to measure. A scoped
    # builder fails honestly.
    if os.environ.get("DEMO_PROVISION_BUILDER") == "1":
        builder_cts = scoped_content_types(
            app_labels=SCOPED_APP_LABELS,
            exclude=EXCLUDED_MODELS | NEVER_WRITABLE_MODELS,
        )
        builder_perms = view_perms + permissions_for(
            builder_cts, ["add", "change", "delete"]
        )
        user, _ = upsert_user("demo-builder")
        set_permissions(user, builder_perms)
        _, raw = upsert_token("demo-builder", user, "read_write")
        print(f"  demo-builder    tier=read_write  BUILD-ONLY perms={len(builder_perms)}  token={raw}")
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

    # ── OAuth client ───────────────────────────────────────────────────────
    ro = User.objects.get(username="demo-readonly")
    upsert_oauth_client(ro)
    print(f"  oauth client    tier=read  user=demo-readonly  client_id={OAUTH_CLIENT_ID}")
    print(f"                  secret={OAUTH_CLIENT_SECRET}")
    print(f"                  redirect_uris={len(OAUTH_REDIRECT_URIS)}  grants={OAUTH_GRANT_TYPES}")

    print("Done.")


main()
