"""
nautobot_config.py — frisian-mcp demo host (Nautobot 3.2.x).

Baked into ghcr.io/frisian-mcp/demo-nautobot at build time, replacing the base
image's generated config wholesale.

POSTURE: LOCKED.
    Nautobot's native state. A token is required for everything; nothing is
    visible unauthenticated. There is no open/scoped profile switch and no
    open-world read door — this is a config people run on their own laptops,
    not a public showcase behind a load balancer.

WHAT THIS DEMO SHOWS
    Three sibling MCP doors, all authenticated, with different tier ceilings
    (ADR-010 per-route permission model), plus permission-aware discovery: an
    agent SEES only the actions its Django ObjectPermissions allow. The demo
    identities are provisioned in the baked database.

SAFETY
    This file, the image it lives in, and the database beside it ship
    PUBLISHED, PUBLICLY KNOWN demo credentials by design. Never point this
    stack at anything real, and never expose it to a network you do not
    control. See ../README.md.

⚠️ REQUIRES frisian-mcp >= 1.1.0. DO NOT BUILD THIS AGAINST 1.0.12.
    FRISIAN_MCP_ROUTES (the ADR-010 per-route permission model) does not exist
    before 1.1.0. On an older package the setting is not rejected and not
    warned about — it is simply never read. Measured on 1.0.12:

      * the three doors below are never mounted; /mcp/read-only,
        /mcp/read-write and /mcp/ops all return 404
      * everything collapses onto the package's default /mcp/ mount
      * allow_list and deny_list therefore carve NOTHING, and a read-tier
        token was observed invoking extras -> secret and
        extras -> objectchange successfully

    The lock itself (FRISIAN_MCP_PERMISSION_CLASSES) does hold on 1.0.12 —
    anonymous and bad-token requests get 401 — so the failure is not visible
    from the front door. It is the carve-out that silently disappears, which
    means this file would claim a posture it is not delivering.

    Also silently ignored below 1.1.0: FRISIAN_MCP_USAGE_REPORTING,
    FRISIAN_MCP_USAGE_IN_CONTENT, FRISIAN_MCP_BULK_CREATE_RESOURCES and
    FRISIAN_MCP_TOOL_HINTS.

⚠️ THIS MODULE MUST NEVER RAISE.
    `nautobot_dns_models/__init__.py` does `import nautobot_config as settings`
    at import time and catches ONLY ImportError. Any other exception raised
    while this module executes propagates out of an unrelated plugin import as
    a baffling traceback. Every value below must therefore degrade to a working
    default rather than assert. Do not add `os.environ["..."]` subscripts, and
    do not add a `raise` to "fail fast on misconfiguration" — it will not fail
    where you think it does.
"""

import os
import secrets

# pylint: disable=wildcard-import,unused-wildcard-import
from nautobot.core.settings import *  # noqa: F403
from nautobot.core.settings_funcs import is_truthy  # noqa: F401

# ---------------------------------------------------------------------------
# SECRET_KEY — generated per deployment, persisted, never a literal.
#
# The base Nautobot image's own config defaults SECRET_KEY to a hardcoded
# literal. That literal sits in a public image anyone can `docker pull`, so it
# is not a secret in any sense, and inheriting that shape here would give every
# deployment of this demo an identical, published session-signing key.
#
# It is worse than it looks, because frisian-mcp derives its token HMAC key
# from FRISIAN_MCP_HMAC_KEY *falling back to SECRET_KEY*. A published
# SECRET_KEY would therefore also make every baked demo token forgeable. The
# two are decoupled deliberately — see FRISIAN_MCP_HMAC_KEY below.
#
# So: generate on first boot, persist to the demo_state volume, reuse
# thereafter. If persistence fails (read-only filesystem, volume not mounted)
# fall back to an ephemeral key rather than raising — sessions will not survive
# a restart, but the demo still boots. See the "MUST NEVER RAISE" note above.
# ---------------------------------------------------------------------------
_DEMO_STATE_DIR = os.getenv("FRISIAN_DEMO_STATE_DIR", "/opt/nautobot/demo-state")
_SECRET_KEY_PATH = os.path.join(_DEMO_STATE_DIR, "secret_key")


def _resolve_secret_key() -> str:
    """Return the deployment's SECRET_KEY, generating and persisting if needed."""
    from_env = os.getenv("NAUTOBOT_SECRET_KEY")
    if from_env:
        return from_env

    try:
        with open(_SECRET_KEY_PATH, encoding="utf-8") as handle:
            existing = handle.read().strip()
        if existing:
            return existing
    except OSError:
        pass

    generated = secrets.token_urlsafe(64)
    try:
        os.makedirs(_DEMO_STATE_DIR, exist_ok=True)
        # O_EXCL, not a plain write: nautobot, celery_worker and celery_beat all
        # import this module, so two processes can reach here at once. The loser
        # of the race reads the winner's key instead of overwriting it — which
        # would otherwise invalidate the winner's already-signed sessions.
        handle_fd = os.open(_SECRET_KEY_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(handle_fd, generated.encode("utf-8"))
        finally:
            os.close(handle_fd)
    except FileExistsError:
        try:
            with open(_SECRET_KEY_PATH, encoding="utf-8") as handle:
                winner = handle.read().strip()
            if winner:
                return winner
        except OSError:
            pass
    except OSError:
        # Not persistable. Ephemeral key; the demo still boots.
        pass

    return generated


SECRET_KEY = _resolve_secret_key()

# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------
# Nautobot's convention is WHITESPACE-separated, not comma-separated. Using
# .split(",") here yields one unsplit string and rejects every hostname.
ALLOWED_HOSTS = os.getenv(
    "NAUTOBOT_ALLOWED_HOSTS", "localhost 127.0.0.1 [::1]"
).split()

# Never on for a published image: DEBUG leaks settings and stack traces to
# anyone who can reach the port.
DEBUG = is_truthy(os.getenv("NAUTOBOT_DEBUG", "False"))

# The DB/Redis defaults below match the published values in .env.example. They
# are demo credentials for a loopback-bound container and are public by design;
# they are defaulted rather than required so that `docker compose up` still
# works if .env is edited or deleted.
DATABASES = {
    "default": {
        "NAME": os.getenv("NAUTOBOT_DB_NAME", "nautobot"),
        "USER": os.getenv("NAUTOBOT_DB_USER", "nautobot"),
        "PASSWORD": os.getenv("NAUTOBOT_DB_PASSWORD", "nautobot"),
        "HOST": os.getenv("NAUTOBOT_DB_HOST", "db"),
        "PORT": os.getenv("NAUTOBOT_DB_PORT", "5432"),
        "CONN_MAX_AGE": int(os.getenv("NAUTOBOT_DB_TIMEOUT", "300")),
        "ENGINE": "django.db.backends.postgresql",
    }
}

REDIS_HOST = os.getenv("NAUTOBOT_REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("NAUTOBOT_REDIS_PORT", "6379"))
REDIS_PASSWORD = os.getenv("NAUTOBOT_REDIS_PASSWORD", "nautobot")

CACHES = {
    "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": f"redis://:{REDIS_PASSWORD}@{REDIS_HOST}:{REDIS_PORT}/1",
        "TIMEOUT": 300,
        "OPTIONS": {"CLIENT_CLASS": "django_redis.client.DefaultClient"},
    }
}

# ---------------------------------------------------------------------------
# Heavy-response continuation cache (W016).
#
# frisian_mcp.W016 warns that continuation entries default to the SAME cache
# that holds OAuth authorization codes and the token-endpoint rate counter, so
# flooding one evicts the others — and the rate limiter fails OPEN when its
# cache is unavailable. Continuation entries are attacker-amplifiable: an
# unauthenticated caller can mint them.
#
# ⚠️ THIS DEMO USES LOGICAL DB 2 ON THE ONE REDIS, AND THAT IS NOT ISOLATION.
#
# Read W016's own text before "fixing" this. It says absence of the warning is
# NOT proof of isolation, because two aliases on different logical DBs of one
# instance have distinct LOCATION strings and still share that instance's
# memory. The requirement is an independent eviction BUDGET, which settings
# alone cannot express.
#
# So the check below will pass, and its passing means nothing for this
# property. That is a deliberate trade, made 2026-08-25: the demo matches a
# stock Nautobot deployment's one-Redis shape, and it binds to loopback with
# credentials that are published anyway. A production host wanting the real
# property needs a SECOND REDIS INSTANCE, not a different DB index — that is
# what the deployed reference does and what a real deployment should copy.
#
# ⚠️ THE ALIAS AND THE CACHE ARE SET TOGETHER, ON PURPOSE. Naming an alias that
# CACHES does not define is frisian_mcp.E009 — an ERROR, not a warning — and
# the base image entrypoint runs `nautobot-server check` and hard-exits on it.
# The container would not boot. Deriving both from the same condition makes
# that drift unreachable rather than merely unlikely: if the URL is absent we
# set neither, W016 goes back to warning, and the stack still comes up.
#
# Do not "tidy" this by setting FRISIAN_MCP_HEAVY_CACHE_ALIAS somewhere else.
# ---------------------------------------------------------------------------
_HEAVY_CACHE_URL = os.getenv("FRISIAN_MCP_HEAVY_CACHE_URL", "").strip()
if _HEAVY_CACHE_URL:
    _HEAVY_CACHE_ALIAS = os.getenv("FRISIAN_MCP_HEAVY_CACHE_ALIAS", "heavy").strip() or "heavy"
    CACHES[_HEAVY_CACHE_ALIAS] = {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": _HEAVY_CACHE_URL,
        # Matches the package default continuation TTL. A continuation token
        # outliving its cache entry is an unredeemable token, which is a
        # confusing failure; keeping them equal avoids inventing a new one.
        "TIMEOUT": 300,
        "OPTIONS": {"CLIENT_CLASS": "django_redis.client.DefaultClient"},
    }
    FRISIAN_MCP_HEAVY_CACHE_ALIAS = _HEAVY_CACHE_ALIAS

# Off by default — a demo should not phone home from someone's laptop.
INSTALLATION_METRICS_ENABLED = is_truthy(
    os.getenv("NAUTOBOT_INSTALLATION_METRICS_ENABLED", "False")
)

# ---------------------------------------------------------------------------
# Plugins.
#
# This set is dictated by the demo database, not chosen: all four have tables
# in the baked dump. Removing one does not slim the image, it breaks the
# restore. Versions are pinned in the Dockerfile.
# ---------------------------------------------------------------------------
PLUGINS = [
    "nautobot_golden_config",
    "nautobot_dns_models",
    "nautobot_bgp_models",
    "nautobot_ssot",
]

PLUGINS_CONFIG = {
    "nautobot_golden_config": {
        "enable_backup": True,
        "enable_compliance": True,
        "enable_intended": True,
        "enable_sotagg": True,
        "enable_plan": True,
        # Deploy pushes config to real devices. There are no real devices here,
        # and a demo must not ship a button that tries.
        "enable_deploy": False,
    },
    "nautobot_dns_models": {},
    "nautobot_bgp_models": {},
    # SSoT core only — the optional integrations need extra dependencies and
    # per-integration enable flags, so the surface stays the two core ViewSets:
    # Sync (history) and SyncLogEntry (logs).
    "nautobot_ssot": {},
}

EXTRA_INSTALLED_APPS = [
    "frisian_mcp",
    "frisian_mcp.contrib.oauth",
    "frisian_mcp.contrib.tokens",
]

# ---------------------------------------------------------------------------
# Audit logging.
#
# Logs the RESOLVED principal and effective_tier for every tool call. On a demo
# whose whole point is per-identity scoping, this is what turns "the agent sees
# nothing" from a mystery into a one-line answer: principal=<who>,
# effective_tier=<what>. Keep it on.
# ---------------------------------------------------------------------------
if "normal_console" in LOGGING.get("handlers", {}):  # noqa: F405
    LOGGING["loggers"]["frisian_mcp.audit"] = {  # noqa: F405
        "handlers": ["normal_console"],
        "level": "INFO",
        "propagate": False,
    }

# ---------------------------------------------------------------------------
# PER-ROUTE PERMISSION MODEL (ADR-010) — three doors, ALL AUTHENTICATED.
#
# The internal showcase deployment these paths came from ran the read-only
# door OPEN-WORLD, bridged by a guest fallback authenticator. None of that
# ships here:
#   * no FRISIAN_MCP_ALLOW_UNAUTHENTICATED
#   * no guest bridge authenticator
#   * no anonymous read surface
#
# What remains is the part actually worth demonstrating: one identity, three
# doors, three different tier ceilings, and a discovery surface that changes
# per principal. The ceiling only ever NARROWS — it never grants. A read-tier
# token on the admin door is still a read-tier token.
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

# Secrets material and the object-change audit trail never leave the admin
# door. Absent from a route is byte-identical to never-registered — a caller
# cannot tell a carved-out resource from one that does not exist.
_SCOPED_ALLOW = [
    "dcim",
    "ipam",
    "circuits",
    "tenancy",
    "virtualization",
    "wireless",
    "cloud",
    "load_balancers",
    "golden_config",
    "dns",
    "bgp",
    "ssot",
    "extras",
]
# Shared by BOTH scoped doors.
#
# Two categories, kept together because they are denied for the same reason —
# a caller on a scoped door should not be able to name them at all.
#
# 1. Credential material and the audit trail. These never leave the admin door.
# 2. The code-execution surface (S-1). Each of these is remote code execution
#    wearing a data model: a GitRepository is an arbitrary URL the server
#    clones and loads Jobs from; a Webhook is an arbitrary outbound POST an
#    attacker controls the target of; an ExportTemplate is server-rendered
#    Jinja2; JobHook / JobButton / ScheduledJob all bind a Job to a trigger.
#    Denying them costs the demo nothing — nobody comes here to write a webhook
#    — and "it is on loopback" is not a defence when .env.example documents
#    DEMO_BIND_HOST=0.0.0.0 as supported.
_SCOPED_DENY = [
    # Credential material + audit trail
    "extras:secret",
    "extras:secretsgroup",
    "extras:secretsgroupassociation",
    "extras:objectchange",
    # Code-execution surface
    "extras:gitrepository",
    "extras:webhook",
    "extras:externalintegration",
    "extras:jobhook",
    "extras:jobbutton",
    "extras:scheduledjob",
    "extras:exporttemplate",
    "extras:fileproxy",
]

# Read-WRITE door only. Deliberately asymmetric, and the asymmetry is the point.
#
# `JobViewSetBase.run` and `GraphQLQueryViewSet.run` are both
# @action(methods=["post"]), and a Nautobot Job is arbitrary Python. Any POST
# resolves to the read_write permission tier, and the route ceiling tier-filters
# the action list — so on the READ-ceiling door `job -> run` is already absent
# without any deny_list involvement, while `job -> list` and `job -> retrieve`
# remain. Denying `job` on both doors would throw away the Jobs catalogue for
# no security gain.
#
# Note this demo runs a live celery_worker, so the worker-count guard that
# makes `run` fail harmlessly on a worker-less host does NOT apply here. These
# genuinely execute.
#
# Net effect: you can browse the Jobs catalogue on the read-only door, and the
# MORE privileged door deliberately carries less surface. "More tier does not
# mean more surface" is a sharper thing to demonstrate than a symmetric list.
_RW_ONLY_DENY = [
    "extras:job",
    "extras:graphqlquery",
]

FRISIAN_MCP_ROUTES = {
    # Read-only door. `users` (accounts, API tokens, object permissions) is
    # never allowed here — absent, not denied.
    "default": {
        "path": "mcp/read-only",
        "highest_tier": "read",
        "allow_list": list(_SCOPED_ALLOW),
        "deny_list": list(_SCOPED_DENY),
    },
    # Read/write door: same carved surface, write tier unlocked. The caller's
    # own token tier still applies.
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
    # .mcp.json / .cursor/mcp.json / .codex/config.toml are `nautobot-ops`.
    "admin": {
        "path": "mcp/ops",
        "highest_tier": "admin",
        "allow_list": ["*"],
    },
}

# ---------------------------------------------------------------------------
# THIS IS THE LOCK. Do not remove it to "make the demo easier to try".
#
# Route permission resolution: a global FRISIAN_MCP_PERMISSION_CLASSES list
# overrides ALL routes verbatim. That is exactly what a locked posture wants —
# with it set, every door including `default` requires an authenticated
# principal, and anonymous POST and GET/SSE alike get 401 + WWW-Authenticate.
#
# Without it, the package's fallback leaves `default` OPEN. The upstream
# showcase config relied on that on purpose. Deleting this line therefore does
# not "loosen" the demo slightly — it silently republishes an open-world read
# door onto whatever estate is in the database.
# ---------------------------------------------------------------------------
FRISIAN_MCP_PERMISSION_CLASSES = ["rest_framework.permissions.IsAuthenticated"]

# No open door to acknowledge. Left explicit rather than absent so that the
# intent is legible and a future edit has to argue with a written value.
FRISIAN_MCP_ALLOW_UNAUTHENTICATED = False

# NOTE: FRISIAN_MCP_UNAUTHENTICATED_TIER is deliberately NOT relied upon as a
# control here. On released builds up to and including 1.1.0 its lockdown path
# is a no-op, so it is not a lock — it is a preference that reads like one.
# Authentication is enforced by FRISIAN_MCP_PERMISSION_CLASSES above, which is
# a real gate. Do not swap one for the other.

# ---------------------------------------------------------------------------
# ⛔ DO NOT SET `EXEMPT_VIEW_PERMISSIONS`. Learned the hard way, 2026-07-13.
#
# It is the tempting quick way to hand a caller a read surface, and it works.
# It also SILENTLY DESTROYS PER-USER SCOPING ON EVERY OTHER ROUTE.
#
# `EXEMPT_VIEW_PERMISSIONS = "*"` grants `view_<model>` on every non-excluded
# model to EVERY authenticated principal. Observed live: a service account
# scoped by ObjectPermission to DNS models only connected to the read/write
# door and received read on the entire estate — dcim, ipam, circuits, cloud,
# tenancy, virtualization. Permission-aware discovery was working perfectly and
# faithfully reported the capabilities it was handed; the capabilities were
# wrong. The only thing still scoping that account was the tier ceiling, not
# its permissions.
#
# The lesson generalises: a global view exemption and per-principal permission
# scoping are MUTUALLY EXCLUSIVE. If FRISIAN_MCP_PERMISSION_AWARE_DISCOVERY is
# to mean anything, every principal earns its capabilities from a real
# ObjectPermission. Nautobot's own default is []. Leave it there.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Authenticator ordering — LOAD-BEARING AT TWO LEVELS. Carried across from the
# upstream deployment along with its rationale; do not re-derive it.
#
# 1. frisian-mcp's authenticators MUST come before Nautobot's own
#    TokenAuthentication. Nautobot's class eats any Bearer header it sees and
#    rejects frisian-mcp tokens with AuthenticationFailed.
#
# 2. WITHIN this list, FrisianMcpTokenAuthentication MUST come BEFORE
#    OAuthTokenAuthentication. Both use the `Bearer` prefix and both raise
#    AuthenticationFailed on a lookup miss, so whichever runs first against a
#    foreign token stops the chain dead — and DRF then builds the
#    WWW-Authenticate response from the FIRST class's authenticate_header.
#    With OAuth first, a valid static token gets a 401 carrying an OAuth
#    challenge, which sends OAuth-capable clients down a dynamic client
#    registration path that REGISTRATION_OPEN=False has closed. They bounce
#    with "Incompatible auth server: does not support dynamic client
#    registration" — an error that says nothing about the real cause.
#
# Static-token-first gives mcp.json-style connectors a clean validation path.
# OAuth-issued tokens still authenticate: the static class returns None when
# the header is not one of its own, and OAuth runs second.
# ---------------------------------------------------------------------------
FRISIAN_MCP_AUTHENTICATION_CLASSES = [
    "frisian_mcp.contrib.tokens.authentication.FrisianMcpTokenAuthentication",
    "frisian_mcp.contrib.oauth.authentication.OAuthTokenAuthentication",
]

# ---------------------------------------------------------------------------
# frisian-mcp token HMAC key — A FIXED, PUBLISHED DEMO CONSTANT. Not a secret.
#
# Tokens are stored as HMAC-SHA256(raw_token, key), where the key is
# FRISIAN_MCP_HMAC_KEY falling back to SECRET_KEY.
#
# SECRET_KEY is generated per deployment (above), so if this were left to fall
# through, every token baked into the demo database would be unverifiable on
# first boot: the rows are present, auth simply fails, and there is no useful
# error message anywhere. That failure is silent and looks like a broken image.
#
# CHANGING THIS VALUE BREAKS EVERY BAKED DEMO TOKEN. It is published on
# purpose; the tokens it covers ship inside the image by design, so the key
# protects nothing that is not already public. Do not "improve security" by
# randomising it — that is not a hardening, it is a self-inflicted outage.
#
# It is also why the tokens must be MINTED under this key: provisioning has to
# run with it already set.
# ---------------------------------------------------------------------------
FRISIAN_MCP_HMAC_KEY = os.getenv(
    "FRISIAN_MCP_HMAC_KEY", "frisian-mcp-demo-public-hmac-key-do-not-reuse"
)

# ---------------------------------------------------------------------------
# OAuth.
# ---------------------------------------------------------------------------
# Public origin as the client reaches it. The demo is loopback-bound by
# default; override when fronting it with anything else, or OAuth redirects
# will point somewhere the browser cannot follow.
#
# ⚠️ `127.0.0.1`, NOT `localhost`, AND THE TWO ARE NOT INTERCHANGEABLE HERE.
#
# This value is echoed verbatim as `resource` in the protected-resource
# metadata a 401 points at. RFC 9728 has the client check that `resource`
# matches the URL it actually connected to, and it is a STRING comparison —
# `http://localhost:8080/mcp/ops` does not match a connection to
# `http://127.0.0.1:8080/mcp/ops`, however identical the two hosts are.
#
# Everything else in this demo says 127.0.0.1: the compose bind, all three
# shipped client configs, and the docs. This said `localhost`, so a strict
# OAuth client was refused by its own origin check — and the failure reads as
# a broken server rather than a mismatched string.
#
# Browsers tolerate either, so the consent screen is unaffected. The MCP
# client is the one doing the comparison, so the connection URL wins.
FRISIAN_MCP_OAUTH_ISSUER = os.getenv(
    "FRISIAN_MCP_OAUTH_ISSUER", "http://127.0.0.1:8080"
)

# Zero, not two. The upstream deployment sat behind an ALB plus an nginx
# reverse proxy and set 2 to resolve the real client from X-Forwarded-For. This
# demo has no proxy in front of it, and trusting a forwarded header that
# nothing in the chain writes lets a caller spoof its own source address.
FRISIAN_MCP_TRUSTED_PROXY_COUNT = int(os.getenv("FRISIAN_MCP_TRUSTED_PROXY_COUNT", "0"))

# Client lifecycle: every minting path stays shut.
#
# The hazard is the COMBINATION — REGISTRATION_OPEN + PKCE_AUTO_REGISTER +
# AUTO_APPROVE with an empty host allowlist lets any caller mint a client
# anonymously and PKCE straight to a Bearer token with no human in the loop.
# That was confirmed live on a previous deployment. Each link is gated
# independently; on a demo that anyone can reach, all of them stay closed.
FRISIAN_MCP_OAUTH_REGISTRATION_OPEN = False
FRISIAN_MCP_OAUTH_PKCE_AUTO_REGISTER = False
FRISIAN_MCP_OAUTH_AUTO_APPROVE = False

# A walk-up client lands at the LOWEST tier. DO NOT RAISE THIS. To give a
# specific client more, promote its OAuthClient row in Django admin and
# reconnect — token authority is fixed at issuance, so promoting the client
# does not widen tokens already issued. The reconnect is required by design.
FRISIAN_MCP_OAUTH_PKCE_DEFAULT_PERMISSION = "read"

# 24 hours, not the upstream deployment's 1 year. A year-long bearer token is
# defensible for a monitored showcase host with a rotation story; it is not
# defensible in an image published to strangers, where an accidentally-shared
# token has no expiry anyone will notice. A demo is re-run, not kept alive.
FRISIAN_MCP_OAUTH_TOKEN_EXPIRY_SECONDS = int(
    os.getenv("FRISIAN_MCP_OAUTH_TOKEN_EXPIRY_SECONDS", str(60 * 60 * 24))
)

# Public discovery stays ON, and this was reconsidered under the locked posture
# rather than inherited.
#
# The instinct is to switch it off — locked door, hide the signposts. It does
# not work that way. A spec-compliant MCP client that gets a 401 follows the
# RFC 9728 -> RFC 8414 cascade to learn where the authorization server lives:
#     GET /.well-known/oauth-protected-resource/<path>
#     GET /.well-known/oauth-protected-resource
#     GET /.well-known/oauth-authorization-server
# With this False all three return 404, the client has no authorization
# endpoint, and it falls back to guessing /authorize at the site root — which
# is not where the package mounts it. The connector then dead-ends on an HTML
# 404 with no diagnosable cause. That is precisely the failure a first-time
# demo user cannot debug.
#
# What it exposes is bounded by specification: these documents advertise
# endpoint URLs, not credentials, and `registration_endpoint` is advertised
# only when REGISTRATION_OPEN is True — which it is not. Callers still need a
# pre-registered client, operator consent, and a valid token.
FRISIAN_MCP_OAUTH_PUBLIC_DISCOVERY = True

# ---------------------------------------------------------------------------
# Discovery + response surface — the features the demo exists to show.
# ---------------------------------------------------------------------------
# Rebuild dispatcher action enums per request so an agent only SEES the actions
# its Django permissions allow. A principal whose ObjectPermission covers DNS
# records sees the DNS dispatcher and nothing else; other resources are ABSENT
# from tools/list, not merely refused at execution.
FRISIAN_MCP_PERMISSION_AWARE_DISCOVERY = True

# FRISIAN_MCP_PERMISSION_ADAPTER is deliberately NOT set. The package default
# resolves each capability through user.has_perm(), which on Nautobot means the
# principal's real ObjectPermissions — the only capability source we want. See
# the EXEMPT_VIEW_PERMISSIONS block above for what happens when something
# synthesizes capabilities instead.

# Token-usage reporting on and model-visible. This is a demonstration instance:
# every agent on every route should SEE the token counter without opting in,
# including the model itself via the in-content line. A caller can still opt out
# per request.
FRISIAN_MCP_USAGE_REPORTING = True
FRISIAN_MCP_USAGE_IN_CONTENT = True

# Nautobot's BulkModelViewSet exposes bulk_update / bulk_partial_update /
# bulk_destroy as @action methods but NOT bulk_create; the package synthesizes
# it and routes it to the host's create() with a list body.
FRISIAN_MCP_BULK_CREATE_RESOURCES = "*"

# ---------------------------------------------------------------------------
# Dispatcher groups — Nautobot 3.x core plus the four plugin surfaces.
#
# Basenames follow DRF convention: Model._meta.object_name.lower().
#
# ⚠️ THIS LIST IS AN ALLOW-LIST, AND THE PACKAGE DOES NOT WARN ABOUT WHAT IT
# OMITS. The asymmetry is the trap:
#
#   listed but NOT registered   -> startup WARNING, group entry skipped. Safe.
#   registered but NOT listed   -> published as ~10 FLAT tools. SILENT.
#
# So a Nautobot upgrade that adds a model silently adds a pile of ungrouped
# tools, and `nautobot-server check` still reports "no issues". Measured on
# 3.2.3: cabletype, cabletocabletermination (dcim/0086, dcim/0088) and
# ipaddressrange (ipam/0057) were absent from this list and appeared as 30 flat
# tools on the ops door — against 17 dispatchers, on the one door that shows
# the full surface, undercutting exactly the "N endpoints collapse into 17
# tools" point the demo exists to make. They are folded in below.
#
# WHEN YOU BUMP NAUTOBOT, RE-DERIVE THIS LIST. Compare the ops door's
# tools/list against the dispatchers: anything flat is a resource no group
# claims.
# ---------------------------------------------------------------------------
FRISIAN_MCP_DISPATCH_GROUPS = {
    "dcim": [
        # Core DCIM
        "device", "rack", "rackgroup", "rackreservation",
        "interface", "interfacetemplate",
        "interfaceredundancygroup", "interfaceredundancygroupassociation",
        "interfacevdcassignment",
        "cable", "cabletype", "cabletocabletermination",
        "location", "locationtype",
        "manufacturer", "devicetype", "devicefamily", "deviceredundancygroup",
        "devicebay", "devicebaytemplate",
        "devicetypetosoftwareimagefile", "deviceclusterassignment",
        "platform", "inventoryitem",
        # Console / power ports + templates
        "consoleport", "consoleporttemplate",
        "consoleserverport", "consoleserverporttemplate",
        "powerport", "powerporttemplate",
        "poweroutlet", "poweroutlettemplate",
        "powerfeed", "powerpanel",
        "frontport", "frontporttemplate",
        "rearport", "rearporttemplate",
        # Modules
        "module", "modulebay", "modulebaytemplate",
        "modulefamily", "moduletype",
        # Controllers (Nautobot 2.x+)
        "controller", "controllermanageddevicegroup",
        "controllermanageddevicegroupradioprofileassignment",
        "controllermanageddevicegroupwirelessnetworkassignment",
        # Virtual chassis / device contexts
        "virtualchassis", "virtualdevicecontext",
        # Software (image / version)
        "softwareimagefile", "softwareversion",
        # Connection list endpoints
        "connected_device", "consoleconnections",
        "interfaceconnections", "powerconnections",
    ],
    "ipam": [
        "ipaddress", "ipaddressrange", "ipaddresstointerface",
        "prefix", "prefixlocationassignment",
        "vlan", "vlangroup", "vlanlocationassignment",
        "vrf", "vrfdeviceassignment", "vrfprefixassignment",
        "routetarget", "namespace",
        "rir", "service",
    ],
    "circuits": [
        "circuit", "circuittype", "circuittermination",
        "provider", "providernetwork",
    ],
    "tenancy": [
        "tenant", "tenantgroup",
        "contact", "contactassociation", "team",
    ],
    "virtualization": [
        "cluster", "clustergroup", "clustertype",
        "virtualmachine", "vminterface",
    ],
    "wireless": [
        "wirelessnetwork", "radioprofile", "supporteddatarate",
    ],
    "cloud": [
        "cloudaccount", "cloudnetwork", "cloudnetworkprefixassignment",
        "cloudresourcetype", "cloudservice", "cloudservicenetworkassignment",
    ],
    "vpn": [
        # Nautobot 2.x VPN models — kept for compat; will emit a warning if
        # the running Nautobot doesn't ship them in 3.x.
        "vpn", "vpnphase1policy", "vpnphase2policy",
        "vpnprofile",
        "vpnprofilephase1policyassignment", "vpnprofilephase2policyassignment",
        "vpntermination", "vpntunnel", "vpntunnelendpoint",
    ],
    "load_balancers": [
        "loadbalancerpool", "loadbalancerpoolmember",
        "loadbalancerpoolmembercertificateprofileassignment",
        "virtualserver", "virtualservercertificateprofileassignment",
        "certificateprofile", "healthcheckmonitor",
    ],
    "users": [
        "user", "group", "token", "objectpermission",
        "userconfig", "savedview", "usersavedviewassociation",
    ],
    "approvalworkflow": [
        "approvalworkflow", "approvalworkflowdefinition",
        "approvalworkflowstage", "approvalworkflowstagedefinition",
        "approvalworkflowstageresponse",
        "approvee_dashboard", "approver_dashboard",
    ],
    "data_validation": [
        "minmaxvalidationrule", "regularexpressionvalidationrule",
        "requiredvalidationrule", "uniquevalidationrule",
        "datacompliance",
    ],
    # nautobot-app-golden-config plugin.  Current PyPI version registers 10
    # ViewSets (was 9 in old_builds — `configtopush` is the new one for the
    # config-postprocessing endpoint).
    "golden_config": [
        "goldenconfig", "goldenconfigsetting",
        "compliancefeature", "compliancerule", "configcompliance",
        "configremove", "configreplace",
        "remediationsetting", "configtopush", "configplan",
    ],
    # nautobot-app-dns-models plugin.  Basenames verified against
    # nautobot_dns_models/api/urls.py — 13 ViewSets, no rename vs old_builds.
    "dns": [
        "dnsview", "dnsviewprefixassignment",
        "dnsregistrar", "dnsregistration", "dnszone",
        "nsrecord", "arecord", "aaaarecord",
        "cnamerecord", "mxrecord", "txtrecord",
        "ptrrecord", "srvrecord",
    ],
    # nautobot-app-bgp-models plugin.  Basenames (DRF default = model object_name
    # lowercased) verified against nautobot_bgp_models/api/urls.py — 10 ViewSets.
    "bgp": [
        "autonomoussystem", "autonomoussystemrange",
        "bgproutinginstance",
        "peergroup", "peergrouptemplate",
        "peerendpoint", "peering",
        "addressfamily",
        "peergroupaddressfamily", "peerendpointaddressfamily",
    ],
    # nautobot-ssot plugin.  Core API surface only (integrations disabled).
    # Basenames = Model._meta.object_name.lower(), verified against
    # nautobot_ssot/api/urls.py -> views.py: SyncViewSet (Sync) +
    # SyncLogEntryViewSet (SyncLogEntry).
    "ssot": [
        "sync", "synclogentry",
    ],
    "extras": [
        # Tagging / metadata
        "tag", "configcontext", "configcontextschema",
        "customfield", "customfieldchoice", "customlink",
        "computedfield", "metadatachoice", "metadatatype",
        "objectmetadata",
        # Relationships / dynamic groups / saved views
        "relationship", "relationshipassociation",
        "dynamicgroup", "dynamicgroupmembership",
        "staticgroupassociation",
        # Jobs and automation
        "job", "jobbutton", "jobhook", "jobqueue", "jobqueueassignment",
        "jobresult", "joblogentry", "scheduledjob",
        # Integrations / automation hooks
        "webhook", "externalintegration", "gitrepository", "graphqlquery",
        "exporttemplate", "imageattachment", "fileproxy",
        # Roles / status / secrets
        "role", "status", "secret", "secretsgroup", "secretsgroupassociation",
        # Notes / change tracking / content types
        "note", "objectchange", "contenttype",
    ],
}

# Per-tool hints surface in dispatcher action='help' output so agents
# self-describe expected filters and cross-references without burning a
# round-trip on trial-and-error.  Sourced from old_builds; extend as new
# resource patterns become well-trodden.
FRISIAN_MCP_TOOL_HINTS = {
    # DCIM — devices & topology
    "device_list": "Filter by name, location, status, role, or device_type. Combine with interface_list to trace connectivity.",
    "device_retrieve": "Returns full device detail including platform, location, and config context.",
    "interface_list": "Filter by device or name. Shows cable connections, lag membership, and IP assignments.",
    "interface_retrieve": "Returns full interface detail including speed, mode, and connected endpoint.",
    "cable_list": "Filter by location, status, or device to trace physical connectivity end-to-end.",
    "rack_list": "Filter by location or group. Use rack_retrieve for full U-position inventory.",
    # IPAM — addressing
    "ipaddress_list": "Filter by address, prefix, interface, or dns_name. Use assigned_object_type to scope to devices or VMs.",
    "ipaddress_retrieve": "Returns full address detail including NAT, DNS, and interface assignment.",
    "prefix_list": "Filter by location, VRF, or status. Use prefix_retrieve to see child prefixes and IPs.",
    "vlan_list": "Filter by vid, location, or group. Cross-reference with interface_list for access/trunk membership.",
    # Circuits
    "circuit_list": "Filter by provider, type, or status. Use circuit_retrieve for termination details.",
    # Virtualization
    "virtualmachine_list": "Filter by cluster, status, or platform. Use vminterface_list for VM interface detail.",
    # Golden Config — compliance and config management
    "goldenconfig_list": "Filter by device to see intended, actual, and backup configs. Use goldenconfig_retrieve for full diff output.",
    "configcompliance_list": "Filter by device or feature to check pass/fail compliance status across the fleet.",
    "configplan_list": "Filter by device or plan_type (intended, manual, remediation). Shows pending config changes awaiting deploy.",
    "compliancerule_list": "Filter by feature or platform to see which rules govern compliance checks.",
    "compliancefeature_list": "Lists all named compliance features (e.g. ntp, aaa, bgp). Cross-reference with compliancerule_list.",
    "configremove_list": "Filter by platform to see line-removal rules applied during config rendering.",
    "configreplace_list": "Filter by platform to see regex substitution rules applied during config rendering.",
    # DNS — record lookup and zone management
    "dnszone_list": "Filter by name or view to see all managed DNS zones. Use dnszone_retrieve for SOA and NS details.",
    "arecord_list": "Filter by address or dns_name to map hostnames to IPv4 addresses.",
    "aaaarecord_list": "Filter by address or dns_name to map hostnames to IPv6 addresses.",
    "ptrrecord_list": "Filter by address for reverse DNS lookups. Links back to A/AAAA records.",
    "cnamerecord_list": "Filter by name or target to trace hostname aliases.",
    "mxrecord_list": "Filter by zone to see mail exchange records and priorities.",
    "txtrecord_list": "Filter by zone or name. Includes SPF, DKIM, and other TXT policy records.",
    "srvrecord_list": "Filter by zone or service to see SRV records for service discovery.",
    "dnsview_list": "Lists DNS views (split-horizon scopes). Cross-reference with dnsviewprefixassignment_list for prefix mapping.",
    # SSoT — Single Source of Truth sync history
    "sync_list": "Filter by dry_run or job_result to see past SSoT synchronization runs (data source/target jobs).",
    "synclogentry_list": "Filter by sync, action, or status to see per-object create/update/delete log entries from an SSoT run.",
}
