"""
frisian-mcp demo — Paperless-ngx settings.

THIS FILE IS THE DEMO. Everything else in this directory exists to get it
running. It is mounted into the container from the clone rather than baked in,
so you can read it, change it, `docker compose restart`, and watch the routes
and scopes change.

It imports all of Paperless-ngx's own settings and adds frisian-mcp on top. No
Paperless-ngx source file is modified, and nothing here is vendored: the image
is built FROM the published upstream image.

    DJANGO_SETTINGS_MODULE=paperless_frisian_mcp

Paperless's manage.py, asgi.py and celery.py all use `os.environ.setdefault`,
so the environment variable wins over their `paperless.settings` default and
every process — webserver, consumer, worker, scheduler — picks this up.

⚠️ THIS MODULE MUST NEVER RAISE.

    A settings module that explodes takes the whole container with it, and the
    traceback usually names something unrelated. Every value below degrades to
    a working default rather than raising. If you add something that can fail,
    wrap it.

⚠️ REQUIRES frisian-mcp >= 1.1.0.

    FRISIAN_MCP_ROUTES (the ADR-010 per-route permission model) does not exist
    before 1.1.0. On an older package the setting is not rejected and not
    warned about — it is simply never read, so the three doors below are never
    mounted, /mcp/read-only, /mcp/read-write and /mcp/ops all 404, and
    everything collapses onto the package's default /mcp/ mount.

    The lock itself (FRISIAN_MCP_PERMISSION_CLASSES) does hold on older
    builds, so anonymous requests still get 401 and the failure is invisible
    from the front door. It is the CARVE-OUT that silently disappears — which
    means this file would claim a posture it is not delivering.

    Also silently ignored below 1.1.0: FRISIAN_MCP_USAGE_REPORTING,
    FRISIAN_MCP_USAGE_IN_CONTENT and FRISIAN_MCP_TOOL_HINTS.

    The Dockerfile asserts the hardening symbols are present in the installed
    package, because a version string is not evidence of content.
"""

import os

from paperless.settings import *  # noqa: F401, F403

# ---------------------------------------------------------------------------
# SECRET_KEY — generated per deployment, persisted, never published.
#
# Paperless ships a well-known development SECRET_KEY as its default, and this
# image would otherwise publish it to everyone who pulls it. That is worse than
# it looks: a published SECRET_KEY is a session-forgery key for every copy of
# this demo running anywhere.
#
# It is ALSO why FRISIAN_MCP_HMAC_KEY is set explicitly further down. The token
# digest key falls back to SECRET_KEY when unset, so a per-deployment
# SECRET_KEY would make every token baked into the demo database unverifiable
# on first boot — the rows are present, auth simply fails, and nothing in any
# log says why. The two keys are decoupled deliberately.
#
# So: generate on first boot, persist to the demo_state volume, reuse
# thereafter. If persistence fails (read-only filesystem, volume not mounted)
# fall back to an ephemeral key rather than raising — sessions will not survive
# a restart, but the demo still boots. See the "MUST NEVER RAISE" note above.
# ---------------------------------------------------------------------------
_DEMO_STATE_DIR = os.getenv("FRISIAN_DEMO_STATE_DIR", "/usr/src/paperless/demo-state")
_SECRET_KEY_PATH = os.path.join(_DEMO_STATE_DIR, "secret_key")


def _resolve_secret_key() -> str:
    """Return this deployment's SECRET_KEY, generating and persisting if needed."""
    from_env = os.getenv("PAPERLESS_SECRET_KEY")
    if from_env:
        return from_env

    try:
        with open(_SECRET_KEY_PATH, encoding="utf-8") as fh:
            existing = fh.read().strip()
        if existing:
            return existing
    except OSError:
        pass

    from django.core.management.utils import get_random_secret_key

    generated = get_random_secret_key()
    try:
        os.makedirs(_DEMO_STATE_DIR, exist_ok=True)
        # Written 0600 and then moved into place, so a partial write is never
        # readable as a key.
        tmp = _SECRET_KEY_PATH + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(generated)
        os.replace(tmp, _SECRET_KEY_PATH)
    except OSError:
        # Ephemeral. The demo works; browser sessions do not survive a restart.
        pass
    return generated


SECRET_KEY = _resolve_secret_key()

# ---------------------------------------------------------------------------
# frisian-mcp installation.
#
# Paperless also offers PAPERLESS_APPS for this, and it is the right mechanism
# for a plain install. It is NOT enough here: PAPERLESS_APPS can only append to
# INSTALLED_APPS, and every setting below is a Django setting rather than a
# PAPERLESS_* environment variable. A settings module is the only way to
# express the route model at all.
# ---------------------------------------------------------------------------
INSTALLED_APPS.append("frisian_mcp")  # noqa: F405
INSTALLED_APPS.append("frisian_mcp.contrib.oauth")  # noqa: F405
INSTALLED_APPS.append("frisian_mcp.contrib.tokens")  # noqa: F405

# ---------------------------------------------------------------------------
# The lock. This is the control that makes the posture "locked", and it is a
# real gate rather than a preference.
#
# NOTE: FRISIAN_MCP_UNAUTHENTICATED_TIER is deliberately NOT relied upon here.
# On released builds up to and including 1.1.0 its lockdown path is a no-op —
# it reads like a lock and is not one. Authentication is enforced by the
# permission class below. Do not swap one for the other.
#
# Deleting this line does not "loosen" the demo slightly. It republishes an
# open read door onto the whole estate, to anyone who can reach the port.
# ---------------------------------------------------------------------------
FRISIAN_MCP_PERMISSION_CLASSES = ["rest_framework.permissions.IsAuthenticated"]

# No open door to acknowledge. Left explicit rather than absent so the intent is
# legible and a future edit has to argue with a written value.
FRISIAN_MCP_ALLOW_UNAUTHENTICATED = False

# ---------------------------------------------------------------------------
# Authenticator ordering — LOAD-BEARING.
#
# FrisianMcpTokenAuthentication MUST come BEFORE OAuthTokenAuthentication.
# Both use the `Bearer` prefix and both raise AuthenticationFailed on a lookup
# miss, so whichever runs first against a foreign token stops the chain dead —
# and DRF then builds the WWW-Authenticate response from the FIRST class's
# authenticate_header. With OAuth first, a valid static token gets a 401
# carrying an OAuth challenge, which sends OAuth-capable clients down a dynamic
# client registration path that REGISTRATION_OPEN=False has closed. They bounce
# with "Incompatible auth server: does not support dynamic client registration"
# — an error that says nothing about the real cause.
#
# OAuth-issued tokens still authenticate: the static class returns None when
# the header is not one of its own, and OAuth runs second.
#
# Paperless's own DRF stack is untouched. Its DEFAULT_AUTHENTICATION_CLASSES
# use Basic, `Token` and session auth — none of them claim `Bearer` — so the
# REST API and the MCP doors do not contend for the same header.
# ---------------------------------------------------------------------------
FRISIAN_MCP_AUTHENTICATION_CLASSES = [
    "frisian_mcp.contrib.tokens.authentication.FrisianMcpTokenAuthentication",
    "frisian_mcp.contrib.oauth.authentication.OAuthTokenAuthentication",
]

# ---------------------------------------------------------------------------
# frisian-mcp token HMAC key — A FIXED, PUBLISHED DEMO CONSTANT. Not a secret.
#
# Tokens are stored as HMAC-SHA256(raw_token, key), where the key is
# FRISIAN_MCP_HMAC_KEY falling back to SECRET_KEY. SECRET_KEY is generated per
# deployment above, so leaving this to fall through makes every baked demo
# token dead on first boot, silently.
#
# CHANGING THIS VALUE BREAKS EVERY BAKED DEMO TOKEN. It is published on
# purpose: the tokens it covers ship inside the image by design, so the key
# protects nothing that is not already public. Randomising it is not a
# hardening, it is a self-inflicted outage.
# ---------------------------------------------------------------------------
FRISIAN_MCP_HMAC_KEY = os.getenv(
    "FRISIAN_MCP_HMAC_KEY", "frisian-mcp-demo-public-hmac-key-do-not-reuse"
)

# ---------------------------------------------------------------------------
# Dispatcher groups — Paperless-ngx's ~131 ViewSet actions across 20 ViewSets,
# bundled into seven topic-level tools.
#
# This is the token-economy half of the demo: an agent sees seven tools instead
# of a hundred and thirty-one, and drills in with action="help".
#
# A group naming a resource this Paperless version does not expose is SKIPPED,
# not fatal — which is what lets one list span 2.x releases that gained or
# renamed a ViewSet.
# ---------------------------------------------------------------------------
FRISIAN_MCP_DISPATCH_GROUPS = {
    # The product. UnifiedSearchViewSet plus its custom actions — full-text
    # search, metadata, preview, thumbnail, download, notes, suggestions.
    "documents": ["document"],
    # How a document is filed.
    "classification": [
        "correspondent",
        "documenttype",
        "tag",
        "storagepath",
        "customfield",
    ],
    # Email ingestion.
    "mail": ["mailaccount", "mailrule", "processedmail"],
    # Automation.
    "workflow": ["workflow", "workflowtrigger", "workflowaction"],
    # Public, unauthenticated share URLs.
    "sharing": ["sharelink", "sharelinkbundle"],
    # Accounts and instance configuration. NOT on the scoped doors — see the
    # route model below.
    "system": ["users", "groups", "applicationconfiguration"],
    # Operational surface.
    "monitoring": ["tasks", "logs", "savedview"],
}

# ---------------------------------------------------------------------------
# The carved surface.
#
# Absent from a route is byte-identical to never-registered: a caller cannot
# tell a carved-out resource from one that does not exist. That is the property
# the scoped doors are demonstrating.
# ---------------------------------------------------------------------------
_SCOPED_ALLOW = [
    "documents",
    "classification",
    "mail",
    "workflow",
    "monitoring",
]

# Shared by BOTH scoped doors. Two categories, denied for the same reason — a
# caller on a scoped door should not be able to NAME them at all.
#
# 1. Credential material. A MailAccount holds an IMAP password (and an OAuth
#    refresh token when the account is Gmail/Outlook). It is readable through
#    the API surface as a configuration object; it is credential storage.
#
# 2. Anything that publishes a document to the unauthenticated internet. A
#    ShareLink mints a URL that serves the document with NO authentication —
#    the whole `sharing` group is therefore off both scoped doors, not merely
#    read-only on them. "It is on loopback" is not a defence when .env.example
#    documents DEMO_BIND_HOST=0.0.0.0 as supported.
_SCOPED_DENY = [
    "mail:mailaccount",
]

# Read-WRITE door only. Deliberately asymmetric, and the asymmetry is the point.
#
# A WorkflowAction is an arbitrary outbound request wearing a data model: it
# carries webhook URLs, webhook bodies and headers, and email recipients, and
# the workflow engine fires them on document events. Creating one is
# server-side request forgery with a UI.
#
# On the READ-ceiling door those writes are already impossible — the route's
# `read` tier filters the action list, so `create`/`update`/`destroy` never
# appear — while `list` and `retrieve` remain. So denying the group on both
# doors would throw away the automation catalogue for no security gain.
#
# Net effect: you can BROWSE workflows on the read-only door, and the MORE
# privileged door deliberately carries LESS surface. "More tier does not mean
# more surface" is a sharper thing to demonstrate than a symmetric list.
_RW_ONLY_DENY = [
    "workflow:workflow",
    "workflow:workflowtrigger",
    "workflow:workflowaction",
    "mail:mailrule",
]

# ---------------------------------------------------------------------------
# PER-ROUTE PERMISSION MODEL (ADR-010) — three doors, ALL AUTHENTICATED.
#
# One identity, three doors, three tier ceilings, and a discovery surface that
# changes per principal. The ceiling only ever NARROWS — it never grants. A
# read-tier token on the admin door is still a read-tier token.
#
# PATHS ARE INDEPENDENT — DO NOT NEST THEM. Shared-prefix nesting is legal in
# the package's path validator, but it invites path-prefix confusion between a
# low-privilege door and a privileged one, and any proxy that normalises or
# strips path segments turns that into a real escalation surface. Three
# siblings sharing no prefix cannot be confused for one another by anything in
# the chain.
#
# With FRISIAN_MCP_ROUTES set, the package mounts ONLY these paths.
# FRISIAN_MCP_PATH no longer mounts anything and is deliberately not set.
# ---------------------------------------------------------------------------
FRISIAN_MCP_ROUTES = {
    # Read-only door. `system` (accounts, groups, instance configuration) and
    # `sharing` are never allowed here — absent, not denied.
    "default": {
        "path": "mcp/read-only",
        "highest_tier": "read",
        "allow_list": list(_SCOPED_ALLOW),
        "deny_list": list(_SCOPED_DENY),
    },
    # Read/write door: same carved surface, write tier unlocked. The caller's
    # own token tier and Django permissions still apply, and for demo-editor
    # they are narrower than this door. That gap is the demonstration.
    "elevated": {
        "path": "mcp/read-write",
        "highest_tier": "read_write",
        "allow_list": list(_SCOPED_ALLOW),
        # Base + the read-write-only extension. See _RW_ONLY_DENY above for
        # why this door carries MORE denies than the read-only one.
        "deny_list": list(_SCOPED_DENY) + list(_RW_ONLY_DENY),
    },
    # Full surface, full tier. What the scoped doors made absent is present
    # here — that contrast is the demonstration.
    #
    # ⚠️ THE PATH IS `mcp/ops`, NOT `mcp/admin`, AND THAT IS NOT COSMETIC.
    #
    # An MCP client connecting to `/mcp/admin` STRIPS THE SUFFIX and retries
    # the bare URL, so the caller lands on a different route and authenticates
    # against the read-write tier instead. The admin door is silently absorbed
    # by the write path — it resolves, it answers, and it answers with the
    # wrong ceiling. Nothing on the wire says the route you asked for is not
    # the route you got.
    #
    # The route KEY and `highest_tier` are still "admin"; only the URL segment
    # changed, because the URL is the only part the client rewrites.
    #
    # Do not rename this back for tidiness. Same reason the server entries in
    # .mcp.json / .cursor/mcp.json / .codex/config.toml are `paperless-ops`.
    "admin": {
        "path": "mcp/ops",
        "highest_tier": "admin",
        "allow_list": ["*"],
    },
}

# ---------------------------------------------------------------------------
# Discovery + response surface — the features the demo exists to show.
# ---------------------------------------------------------------------------
# Rebuild dispatcher action enums per request so an agent only SEES the actions
# its Django permissions allow. A principal who can view tags but not change
# them sees `list` and `retrieve` on the classification dispatcher and no
# `update` — absent from tools/list, not merely refused at execution.
FRISIAN_MCP_PERMISSION_AWARE_DISCOVERY = True

# FRISIAN_MCP_PERMISSION_ADAPTER is deliberately NOT set. The package default
# resolves each capability through user.has_perm(), which on Paperless means
# the principal's real Django permissions — the only capability source we want.
# Anything that synthesises capabilities instead makes permission-aware
# discovery faithfully report privileges the principal does not have.

# Token-usage reporting on and model-visible. This is a demonstration instance:
# every agent on every route should SEE the token counter without opting in,
# including the model itself via the in-content line. A caller can still opt out
# per request.
FRISIAN_MCP_USAGE_REPORTING = True
FRISIAN_MCP_USAGE_IN_CONTENT = True

# Cache the tools/list response. Recomputing the permission-aware surface on
# every client connection is the one place this demo can feel slow.
FRISIAN_MCP_TOOLS_LIST_CACHE_TTL = 300

# ---------------------------------------------------------------------------
# Heavy-response continuation cache — a SEPARATE Redis logical DB.
#
# Continuation tokens live here. Sharing the default cache means an eviction
# storm on ordinary cache traffic silently invalidates outstanding tokens, and
# the caller sees a token that simply stops resolving. Paperless uses db 0 for
# the broker, channels and its default cache, so db 2 is free.
#
# Configured only when the compose file supplies a URL, so this module still
# imports cleanly outside the demo stack.
# ---------------------------------------------------------------------------
_HEAVY_CACHE_URL = os.getenv("FRISIAN_MCP_HEAVY_CACHE_URL", "").strip()
if _HEAVY_CACHE_URL:
    CACHES["heavy"] = {  # noqa: F405
        "BACKEND": "django.core.cache.backends.redis.RedisCache",
        "LOCATION": _HEAVY_CACHE_URL,
    }
    FRISIAN_MCP_HEAVY_CACHE_ALIAS = "heavy"

# ---------------------------------------------------------------------------
# OAuth.
# ---------------------------------------------------------------------------
# Public origin as the client reaches it.
#
# ⚠️ `127.0.0.1`, NOT `localhost`, AND THE TWO ARE NOT INTERCHANGEABLE HERE.
#
# This value is echoed verbatim as `resource` in the protected-resource
# metadata a 401 points at. RFC 9728 has the client check that `resource`
# matches the URL it actually connected to, and it is a STRING comparison —
# `http://localhost:8081/mcp/ops` does not match a connection to
# `http://127.0.0.1:8081/mcp/ops`, however identical the two hosts are.
#
# Everything else in this demo says 127.0.0.1: the compose bind, all three
# shipped client configs, and the docs. Browsers tolerate either, so the
# consent screen is unaffected — the MCP client is the one doing the
# comparison, so the connection URL wins.
FRISIAN_MCP_OAUTH_ISSUER = os.getenv(
    "FRISIAN_MCP_OAUTH_ISSUER", "http://127.0.0.1:8081"
)

# Zero. This demo has no proxy in front of it, and trusting a forwarded header
# that nothing in the chain writes lets a caller spoof its own source address.
FRISIAN_MCP_TRUSTED_PROXY_COUNT = int(os.getenv("FRISIAN_MCP_TRUSTED_PROXY_COUNT", "0"))

# Client lifecycle: every minting path stays shut.
#
# The hazard is the COMBINATION — REGISTRATION_OPEN + PKCE_AUTO_REGISTER +
# AUTO_APPROVE with an empty host allowlist lets any caller mint a client
# anonymously and PKCE straight to a Bearer token with no human in the loop.
# Each link is gated independently; on a demo that anyone can reach, all of
# them stay closed.
FRISIAN_MCP_OAUTH_REGISTRATION_OPEN = False
FRISIAN_MCP_OAUTH_PKCE_AUTO_REGISTER = False
FRISIAN_MCP_OAUTH_AUTO_APPROVE = False

# A walk-up client lands at the LOWEST tier. DO NOT RAISE THIS. To give a
# specific client more, promote its OAuthClient row in Django admin and
# reconnect — token authority is fixed at issuance, so promoting the client
# does not widen tokens already issued. The reconnect is required by design.
FRISIAN_MCP_OAUTH_PKCE_DEFAULT_PERMISSION = "read"

# 24 hours. A year-long bearer token is defensible for a monitored showcase
# host with a rotation story; it is not defensible in an image published to
# strangers, where an accidentally-shared token has no expiry anyone will
# notice. A demo is re-run, not kept alive.
FRISIAN_MCP_OAUTH_TOKEN_EXPIRY_SECONDS = int(
    os.getenv("FRISIAN_MCP_OAUTH_TOKEN_EXPIRY_SECONDS", str(60 * 60 * 24))
)

# Public discovery stays ON, and this was reconsidered under the locked posture
# rather than inherited.
#
# The instinct is to switch it off — locked door, hide the signposts. It does
# not work that way. A spec-compliant MCP client that gets a 401 follows the
# RFC 9728 -> RFC 8414 cascade to learn where the authorization server lives.
# With this False all of those return 404, the client has no authorization
# endpoint, and it falls back to guessing /authorize at the site root — which
# is not where the package mounts it. The connector then dead-ends on an HTML
# 404 with no diagnosable cause.
#
# What it exposes is bounded by specification: these documents advertise
# endpoint URLs, not credentials, and `registration_endpoint` is advertised
# only when REGISTRATION_OPEN is True — which it is not.
FRISIAN_MCP_OAUTH_PUBLIC_DISCOVERY = True

# ---------------------------------------------------------------------------
# Audit logging.
#
# Logs the RESOLVED principal and effective_tier for every tool call. On a demo
# whose whole point is per-identity scoping, this is what turns "the agent sees
# nothing" from a mystery into a one-line answer: principal=<who>,
# effective_tier=<what>. Keep it on.
#
# Guarded rather than assumed: Paperless's LOGGING dict is upstream's, and a
# handler name that disappears must not take the container down with it.
# ---------------------------------------------------------------------------
if "console" in LOGGING.get("handlers", {}):  # noqa: F405
    LOGGING["loggers"]["frisian_mcp.audit"] = {  # noqa: F405
        "handlers": ["console"],
        "level": "INFO",
        "propagate": False,
    }
