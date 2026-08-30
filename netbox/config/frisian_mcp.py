"""
frisian-mcp demo — NetBox settings.

THIS FILE IS THE DEMO. Everything else in this directory exists to get it
running. docker-compose.yml mounts it over netbox-docker's own
``/etc/netbox/config/extra.py``, which is that image's documented place for
"configuration options that can't be configured directly through environment
variables". So it stays readable and editable in the clone: change it,
``docker compose restart``, and watch the routes and scopes change.

No NetBox source file is modified, and nothing is vendored — the image is
built FROM the published upstream image.

⚠️ THIS MODULE MUST NEVER RAISE.

    NetBox imports its configuration at startup. A settings file that explodes
    takes the whole container with it, and the traceback usually names
    something unrelated. Every value below degrades to a working default.

⚠️ WHY A PLUGIN IS INVOLVED AT ALL.

    NetBox does not route third-party URLs through Django's resolver; it loads
    them from a ``PluginConfig``. frisian-mcp's own ``AppConfig.ready()``
    auto-injection — what makes it zero-wiring on stock Django and Paperless —
    does not fire here. ``frisian_mcp_netbox`` is the shim that mounts the MCP,
    OAuth and well-known URLs, and it is baked into the image rather than
    mounted, because NetBox reads ``PLUGINS`` before Django finishes booting.

    That shim is also what copies the ``FRISIAN_MCP_*`` names below onto Django
    settings. NetBox's ``settings.py`` only promotes names it knows, so without
    the plugin every setting in this file would be silently ignored — present
    in the config module, absent from ``django.conf.settings``, and nothing
    anywhere would say so.

⚠️ REQUIRES frisian-mcp >= 1.1.0.

    ``FRISIAN_MCP_ROUTES`` does not exist before 1.1.0. On an older package the
    setting is not rejected and not warned about — it is simply never read, the
    three doors never mount, and everything collapses onto one endpoint that
    still answers 401 to anonymous callers. The carve-out disappears silently,
    which means this file would claim a posture it is not delivering. The
    Dockerfile asserts the symbols are present, because a version string is not
    evidence of content.
"""

import os

# ---------------------------------------------------------------------------
# SECRET_KEY — generated per deployment, persisted, never published.
#
# netbox-docker REQUIRES this and does not generate one. Without it the
# entrypoint fails while loading settings, and it reports that as
# "⏳ Waiting on DB..." followed by "Waited 30s or more for the DB to become
# ready" — a message about the database, for a problem that has nothing to do
# with the database. Measured; it cost a build to diagnose.
#
# It is set HERE rather than in .env because publishing a fixed SECRET_KEY in a
# public repo publishes a session-forgery key for every copy of this demo. The
# frisian-mcp token digests are deliberately NOT tied to it — see
# FRISIAN_MCP_HMAC_KEY below — so a per-deployment SECRET_KEY does not make the
# baked demo tokens unverifiable, which is the trap the Paperless host
# documents at length.
#
# Generate on first boot, persist to the demo_state volume, reuse thereafter.
# If persistence fails (read-only filesystem, volume not mounted) fall back to
# an ephemeral key rather than raising: sessions will not survive a restart,
# but the demo still boots. See the "MUST NEVER RAISE" note above.
# ---------------------------------------------------------------------------
_DEMO_STATE_DIR = os.getenv("FRISIAN_DEMO_STATE_DIR", "/opt/netbox/demo-state")
_SECRET_KEY_PATH = os.path.join(_DEMO_STATE_DIR, "secret_key")


def _resolve_secret_key() -> str:
    """Return this deployment's SECRET_KEY, generating and persisting if needed."""
    from_env = os.getenv("SECRET_KEY")
    if from_env:
        return from_env

    try:
        with open(_SECRET_KEY_PATH, encoding="utf-8") as fh:
            existing = fh.read().strip()
        if existing:
            return existing
    except OSError:
        pass

    import secrets
    import string

    alphabet = string.ascii_letters + string.digits + "!@#$%^&*(-_=+)"
    generated = "".join(secrets.choice(alphabet) for _ in range(64))
    try:
        os.makedirs(_DEMO_STATE_DIR, exist_ok=True)
        # Written 0600 then moved into place, so a partial write is never
        # readable as a key.
        tmp = _SECRET_KEY_PATH + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(generated)
        os.replace(tmp, _SECRET_KEY_PATH)
    except OSError:
        pass
    return generated


SECRET_KEY = _resolve_secret_key()

# ---------------------------------------------------------------------------
# Enable the plugin. This is the line that mounts everything else.
#
# The import is inside a try: netbox-docker's own extra.py demonstrates this
# pattern, and a NetBox release that moves the module must not take the
# container down with an ImportError from a settings file.
# ---------------------------------------------------------------------------
try:
    from netbox.configuration.configuration import PLUGINS  # noqa: F401
except ImportError:  # pragma: no cover - depends on the NetBox release
    PLUGINS = []

if "frisian_mcp_netbox" not in PLUGINS:
    PLUGINS.append("frisian_mcp_netbox")

# ---------------------------------------------------------------------------
# The lock. This is the control that makes the posture "locked", and it is a
# real gate rather than a preference.
#
# NOTE: FRISIAN_MCP_UNAUTHENTICATED_TIER is deliberately NOT relied upon. On
# released builds up to and including 1.1.0 its lockdown path is a no-op — it
# reads like a lock and is not one. Authentication is enforced by the
# permission class below, which is a real gate. Do not swap one for the other.
#
# Deleting this line does not "loosen" the demo slightly. It republishes an
# open read door onto the whole estate, to anyone who can reach the port.
# ---------------------------------------------------------------------------
FRISIAN_MCP_PERMISSION_CLASSES = ["rest_framework.permissions.IsAuthenticated"]
FRISIAN_MCP_ALLOW_UNAUTHENTICATED = False

# ---------------------------------------------------------------------------
# Authenticator ordering — LOAD-BEARING.
#
# FrisianMcpTokenAuthentication MUST come BEFORE OAuthTokenAuthentication.
# Both claim the `Bearer` prefix, so whichever runs first against a foreign
# token stops the chain — and DRF builds the 401 challenge from the FIRST
# class. With OAuth first, a valid static token gets an OAuth challenge and
# compliant clients bounce down a dynamic-registration path that
# REGISTRATION_OPEN=False has closed, reporting an error that says nothing
# about the real cause.
#
# NetBox's own DRF stack is untouched. Its authenticators use `Token` and
# session auth, so the REST API and the MCP doors do not contend for `Bearer`.
# ---------------------------------------------------------------------------
FRISIAN_MCP_AUTHENTICATION_CLASSES = [
    "frisian_mcp.contrib.tokens.authentication.FrisianMcpTokenAuthentication",
    "frisian_mcp.contrib.oauth.authentication.OAuthTokenAuthentication",
]

# ---------------------------------------------------------------------------
# frisian-mcp token HMAC key — A FIXED, PUBLISHED DEMO CONSTANT. Not a secret.
#
# Tokens are stored as HMAC-SHA256(raw, key), the key being this value falling
# back to SECRET_KEY. NetBox's SECRET_KEY is per-deployment, so leaving this to
# fall through makes every baked demo token dead on first boot: the rows are
# there, auth simply fails, and nothing logs why.
#
# CHANGING THIS BREAKS EVERY BAKED DEMO TOKEN. It is published on purpose —
# the tokens it covers ship inside the image by design, so the key protects
# nothing that is not already public.
# ---------------------------------------------------------------------------
FRISIAN_MCP_HMAC_KEY = os.getenv(
    "FRISIAN_MCP_HMAC_KEY", "frisian-mcp-demo-public-hmac-key-do-not-reuse"
)

# ---------------------------------------------------------------------------
# Dispatcher groups — NetBox's 1164 auto-discovered ViewSet actions bundled
# into ten topic-level tools.
#
# This is the token-economy half of the demo, and NetBox is the extreme case:
# 1164 tool schemas is tens of thousands of tokens before an agent has done
# anything. Ten dispatchers is about two thousand.
#
# A group naming a resource this NetBox does not expose is SKIPPED, not fatal,
# which is what lets one list span releases that gain or rename a ViewSet.
# ---------------------------------------------------------------------------
# NOTE the values are RESOURCE names, not app labels.
#
# The first version of this file used app labels — `"dcim": ["dcim"]` — and
# matched nothing: every group logged `has 0 matching tools` and its flat tools
# stayed visible, which would have shipped a demo with 1164 loose tools instead
# of ten dispatchers. Registered NetBox tool names are per-resource
# (`site_list`, `device_list`), so a group must enumerate resources.
#
# These lists are taken verbatim from the reference configuration in
# frisian-mcp's own NetBox install docs, which is the copy users follow.
FRISIAN_MCP_DISPATCH_GROUPS = {
    "dcim": [
        "region", "sitegroup", "site", "location",
        "rackgroup", "racktype", "rackrole", "rack", "rackreservation",
        "manufacturer", "devicetype", "moduletype", "moduletypeprofile",
        "consoleporttemplate", "consoleserverporttemplate",
        "powerporttemplate", "poweroutlettemplate",
        "interfacetemplate", "frontporttemplate", "rearporttemplate",
        "modulebaytemplate", "devicebaytemplate", "inventoryitemtemplate",
        "devicerole", "platform", "device", "virtualdevicecontext", "module",
        "consoleport", "consoleserverport", "powerport", "poweroutlet",
        "interface", "frontport", "rearport",
        "modulebay", "devicebay", "inventoryitem", "inventoryitemrole",
        "macaddress",
        "cable", "cabletermination", "cablebundle",
        "virtualchassis",
        "powerpanel", "powerfeed",
        "connected_device",
    ],
    "ipam": [
        "asn", "asnrange", "vrf", "routetarget", "rir", "aggregate",
        "role", "prefix", "iprange", "ipaddress",
        "fhrpgroup", "fhrpgroupassignment",
        "vlangroup", "vlan", "vlantranslationpolicy", "vlantranslationrule",
        "servicetemplate", "service",
    ],
    "circuits": [
        "provider", "provideraccount", "providernetwork",
        "circuittype", "circuit", "circuittermination",
        "circuitgroup", "circuitgroupassignment",
        "virtualcircuit", "virtualcircuittype", "virtualcircuittermination",
    ],
    "tenancy": [
        "tenantgroup", "tenant",
        "contactgroup", "contactrole", "contact", "contactassignment",
    ],
    "virtualization": [
        "clustertype", "clustergroup", "cluster",
        "virtualmachinetype", "virtualmachine",
        "vminterface", "virtualdisk",
    ],
    "vpn": [
        "ikepolicy", "ikeproposal",
        "ipsecpolicy", "ipsecproposal", "ipsecprofile",
        "tunnelgroup", "tunnel", "tunneltermination",
        "l2vpn", "l2vpntermination",
    ],
    "wireless": [
        "wirelesslangroup", "wirelesslan", "wirelesslink",
    ],
    "extras": [
        "eventrule", "webhook",
        "customfield", "customfieldchoiceset", "customlink",
        "exporttemplate", "savedfilter", "tableconfig",
        "bookmark", "notification", "notificationgroup", "subscription",
        "tag", "taggeditem", "imageattachment", "journalentry",
        "configcontext", "configcontextprofile", "configtemplate",
        "script", "scriptmodule",
    ],
    "users": [
        "user", "group", "token", "objectpermission",
        "ownergroup", "owner", "userconfig",
    ],
    "core": [
        "datasource", "datafile",
        "rqqueue", "rqworker", "rqtask",
        "job", "objectchange", "objecttype",
        "configrevision", "managedfile", "autosyncrecord",
        "background",
    ],
}

# ---------------------------------------------------------------------------
# The carved surface.
#
# Absent from a route is byte-identical to never-registered: a caller cannot
# tell a carved-out resource from one that does not exist. That is the property
# the scoped doors demonstrate.
# ---------------------------------------------------------------------------
_SCOPED_ALLOW = [
    "dcim",
    "ipam",
    "circuits",
    "tenancy",
    "virtualization",
    "vpn",
    "wireless",
    "extras",
]

# Shared by BOTH scoped doors. Two categories, denied for the same reason — a
# caller on a scoped door should not be able to NAME them at all.
#
# 1. The audit trail. `objectchange` is the record of who did what; it never
#    leaves the admin door.
# 2. The code-execution and outbound-request surface. Each of these is remote
#    execution or SSRF wearing a data model: a Webhook is an arbitrary outbound
#    POST an attacker chooses the target of; an ExportTemplate and a
#    ConfigTemplate are both server-rendered Jinja2; a Script is arbitrary
#    Python; an EventRule binds any of them to a trigger. Denying them costs
#    the demo nothing — nobody comes to a NetBox demo to write a webhook — and
#    "it is on loopback" is not a defence when .env.example documents
#    DEMO_BIND_HOST=0.0.0.0 as supported.
_SCOPED_DENY = [
    "extras:objectchange",
    "extras:webhook",
    "extras:eventrule",
    "extras:exporttemplate",
    "extras:configtemplate",
    "extras:script",
]

# Read-WRITE door only. Deliberately asymmetric, and the asymmetry is the point.
#
# A ConfigContext is arbitrary JSON merged into device configuration rendering,
# and a JournalEntry is free text attached to any object. Neither is dangerous
# to READ, and both are useful to browse — so on the read-ceiling door they
# stay, where the tier already makes writes impossible. On the write door they
# go, because that is where writing them becomes possible.
#
# Net effect: the MORE privileged door deliberately carries LESS surface.
# "More tier does not mean more surface" is a sharper thing to demonstrate than
# a symmetric list.
_RW_ONLY_DENY = [
    "extras:configcontext",
    "extras:journalentry",
]

# ---------------------------------------------------------------------------
# PER-ROUTE PERMISSION MODEL — three doors, ALL AUTHENTICATED.
#
# One server, three tier ceilings, and a discovery surface that changes per
# principal. The ceiling only ever NARROWS — it never grants, so a read-tier
# token on the admin door is still a read-tier token.
#
# PATHS ARE INDEPENDENT — DO NOT NEST THEM. Shared-prefix nesting is legal in
# the package's validator, but it invites path-prefix confusion between a
# low-privilege door and a privileged one, and any proxy that normalises or
# strips path segments turns that into a real escalation surface.
#
# ⚠️ THE ADMIN PATH IS `api/mcp/ops`, NOT `.../admin`, AND THAT IS NOT COSMETIC.
#
# An MCP client connecting to a path ending in `admin` STRIPS THE SUFFIX and
# retries the bare URL, so the caller silently lands on a different route and
# authenticates against the write tier instead. Nothing on the wire says the
# route you asked for is not the route you got. Do not rename it back for
# tidiness — the same reason the client configs say `netbox-ops`.
# ---------------------------------------------------------------------------
FRISIAN_MCP_ROUTES = {
    "default": {
        "path": "api/mcp/read-only",
        "highest_tier": "read",
        "allow_list": list(_SCOPED_ALLOW),
        "deny_list": list(_SCOPED_DENY),
    },
    "elevated": {
        "path": "api/mcp/read-write",
        "highest_tier": "read_write",
        "allow_list": list(_SCOPED_ALLOW),
        # Base + the read-write-only extension. See _RW_ONLY_DENY above for
        # why this door carries MORE denies than the read-only one.
        "deny_list": list(_SCOPED_DENY) + list(_RW_ONLY_DENY),
    },
    "admin": {
        "path": "api/mcp/ops",
        "highest_tier": "admin",
        "allow_list": ["*"],
    },
}

# ---------------------------------------------------------------------------
# Discovery + response surface — the features the demo exists to show.
# ---------------------------------------------------------------------------
# Rebuild dispatcher action enums per request so an agent only SEES the actions
# its NetBox permissions allow. A principal granted view on dcim sees the dcim
# dispatcher and nothing else — other resources are ABSENT from tools/list, not
# merely refused at execution.
FRISIAN_MCP_PERMISSION_AWARE_DISCOVERY = True

# FRISIAN_MCP_PERMISSION_ADAPTER is deliberately NOT set. The package default
# resolves each capability through user.has_perm(), which on NetBox means the
# principal's real ObjectPermissions — the only capability source we want.
# Anything that synthesises capabilities instead makes permission-aware
# discovery faithfully report privileges the principal does not have.

FRISIAN_MCP_USAGE_REPORTING = True
FRISIAN_MCP_USAGE_IN_CONTENT = True
FRISIAN_MCP_TOOLS_LIST_CACHE_TTL = 300

# NetBox ViewSets cannot be decorated with @mcp_heavy without editing NetBox
# source, so large responses are negotiated by size instead. This matters more
# here than on the other hosts: a bare `dcim/device/list` on a real estate is
# enormous.
FRISIAN_MCP_AUTO_NEGOTIATE_THRESHOLD = 8_000

# ---------------------------------------------------------------------------
# OAuth.
# ---------------------------------------------------------------------------
# ⚠️ `127.0.0.1`, NOT `localhost`, AND THE TWO ARE NOT INTERCHANGEABLE.
#
# This value is echoed verbatim as `resource` in the protected-resource
# metadata a 401 points at. RFC 9728 has the client check that `resource`
# matches the URL it connected to, and it is a STRING comparison — so
# `http://localhost:8083/...` does not match a connection to
# `http://127.0.0.1:8083/...`, however identical the hosts are. Everything else
# in this demo says 127.0.0.1.
FRISIAN_MCP_OAUTH_ISSUER = os.getenv(
    "FRISIAN_MCP_OAUTH_ISSUER", "http://127.0.0.1:8083"
)

# Zero. This demo has no proxy in front of it, and trusting a forwarded header
# that nothing in the chain writes lets a caller spoof its own source address.
FRISIAN_MCP_TRUSTED_PROXY_COUNT = int(os.getenv("FRISIAN_MCP_TRUSTED_PROXY_COUNT", "0"))

# Every minting path stays shut. The hazard is the COMBINATION —
# REGISTRATION_OPEN + PKCE_AUTO_REGISTER + AUTO_APPROVE lets any caller mint a
# client anonymously and PKCE straight to a Bearer token with no human in the
# loop. Each link is gated independently; on a demo anyone can reach, all of
# them stay closed.
FRISIAN_MCP_OAUTH_REGISTRATION_OPEN = False
FRISIAN_MCP_OAUTH_PKCE_AUTO_REGISTER = False
FRISIAN_MCP_OAUTH_AUTO_APPROVE = False

# A walk-up client lands at the LOWEST tier. DO NOT RAISE THIS. To give a
# client more, promote its OAuthClient row and reconnect — token authority is
# fixed at issuance, so promoting the client does not widen tokens already
# issued. The reconnect is required by design.
FRISIAN_MCP_OAUTH_PKCE_DEFAULT_PERMISSION = "read"

# 24 hours. A year-long bearer token is defensible for a monitored showcase
# with a rotation story; it is not defensible in an image published to
# strangers, where an accidentally-shared token has no expiry anyone notices.
FRISIAN_MCP_OAUTH_TOKEN_EXPIRY_SECONDS = int(
    os.getenv("FRISIAN_MCP_OAUTH_TOKEN_EXPIRY_SECONDS", str(60 * 60 * 24))
)

# Public discovery stays ON, and this was reconsidered under the locked posture
# rather than inherited. The instinct is to switch it off — locked door, hide
# the signposts. It does not work that way: a spec-compliant client that gets a
# 401 follows the RFC 9728 -> RFC 8414 cascade to find the authorization
# server. With this False those all 404, the client has no authorization
# endpoint, and it falls back to guessing `/authorize` at the site root — which
# is not where the package mounts it. What it exposes is bounded by
# specification: endpoint URLs, not credentials, and `registration_endpoint` is
# advertised only when REGISTRATION_OPEN is True, which it is not.
FRISIAN_MCP_OAUTH_PUBLIC_DISCOVERY = True

# ---------------------------------------------------------------------------
# Heavy-response continuation cache (W016).
#
# frisian_mcp.W016 warns that continuation entries default to the SAME cache
# that holds OAuth authorization codes and the token-endpoint rate counter, so
# flooding one evicts the others — and the rate limiter fails OPEN when its
# cache is unavailable. Continuation entries are attacker-amplifiable: an
# unauthenticated caller can mint them.
#
# ⚠️ THIS WARNING IS EXPECTED ON A DEFAULT BOOT, AND ACCEPTING IT IS DELIBERATE.
# It is the same trade the Nautobot demo host documents at length (see
# nautobot/config/nautobot_config.py, dated 2026-08-25) and the Paperless host
# makes silently. Read W016's own text before "fixing" it: absence of the
# warning is NOT proof of isolation, because two aliases on different logical
# DBs of one Redis have distinct LOCATION strings and still share that
# instance's memory. The requirement is an independent eviction BUDGET, which
# settings alone cannot express — it needs a SECOND REDIS INSTANCE, not a
# different DB index.
#
# So the opt-in below silences the check without necessarily delivering the
# property, unless the URL you supply genuinely points at separate infra. That
# is why it is opt-in and off by default: the demo ships the honest warning
# rather than a quiet config that implies a guarantee it does not provide.
# `common/ci/acceptance-netbox.sh` allows W016 by ID for this reason and fails
# on every other frisian_mcp finding.
#
# ⚠️ THE ALIAS AND THE CACHE ARE SET TOGETHER, ON PURPOSE. Naming an alias that
# CACHES does not define is frisian_mcp.E009 — an ERROR, not a warning.
# Deriving both from the same condition makes that drift unreachable rather
# than merely unlikely: if the URL is absent we set neither, W016 stays a
# warning, and the stack still comes up.
#
# Do not "tidy" this by setting FRISIAN_MCP_HEAVY_CACHE_ALIAS somewhere else.
# ---------------------------------------------------------------------------
_HEAVY_CACHE_URL = os.getenv("FRISIAN_MCP_HEAVY_CACHE_URL", "").strip()
if _HEAVY_CACHE_URL:
    _HEAVY_CACHE_ALIAS = os.getenv("FRISIAN_MCP_HEAVY_CACHE_ALIAS", "heavy").strip() or "heavy"
    # netbox-docker builds CACHES from REDIS in configuration.py, and this file
    # is loaded as extra.py AFTER it — so CACHES exists here. Guard anyway: a
    # NameError at import time takes the whole container down with a traceback
    # that names this line and not the reason.
    try:
        CACHES  # noqa: B018
    except NameError:  # pragma: no cover
        CACHES = {}
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
