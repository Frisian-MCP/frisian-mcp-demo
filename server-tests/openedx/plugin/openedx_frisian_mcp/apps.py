"""
Open edX plugin app that mounts frisian-mcp's URLs.

WHY THIS EXISTS AT ALL

Open edX does not use Django's ordinary URL routing for third-party apps. It
injects URLs through `edx_django_utils.plugins`, driven by a `plugin_app`
dict on the AppConfig. frisian-mcp's own `AppConfig.ready()` auto-injection —
which inserts its pattern at position 0 of the root resolver and is what makes
the package zero-wiring on stock Django, Nautobot and Paperless — has no
equivalent here.

So Open edX is the one host so far that genuinely needs a shim, and this is it.
It adds URLs and nothing else. No Open edX source file is modified.

PORTED, NOT COPIED — see the note at the bottom of this file.
"""

from django.apps import AppConfig
from edx_django_utils.plugins import PluginURLs
from openedx.core.djangoapps.plugins.constants import ProjectType


class OpenedxFrisianMcpConfig(AppConfig):
    """Register the MCP, OAuth and well-known URLs with the LMS."""

    name = "openedx_frisian_mcp"
    default_auto_field = "django.db.models.BigAutoField"

    plugin_app = {
        PluginURLs.CONFIG: {
            ProjectType.LMS: {
                # Empty namespace: frisian-mcp's own URL names are already
                # prefixed, and a namespace here would break the reverse()
                # calls the OAuth views make against them.
                PluginURLs.NAMESPACE: "",
                PluginURLs.REGEX: r"^",
                PluginURLs.RELATIVE_PATH: "urls",
            },
        }
    }


# ─────────────────────────────────────────────────────────────────────────────
# WHAT WAS DELIBERATELY LEFT BEHIND
#
# This app is a port of `openedx_friese_mcp/`, the pre-rename scaffold that is
# the only implementation that exists (the install doc points at an
# `openedx_frisian_mcp/` in the package repo that is not there — finding OX-2).
#
# Four modules from that scaffold are NOT ported, and the omissions are listed
# rather than silently dropped, because "the port was clean" only means
# something if you can see what was excluded:
#
#   dev_auth.py                    ⛔ NEVER PORT THIS.
#       `DevServiceUserAuthentication` returns the first superuser for any
#       request that arrives with NO Authorization header, and the settings it
#       shipped beside set FRISIAN_MCP_UNAUTHENTICATED_TIER = "admin" and
#       FRISIAN_MCP_ALLOW_UNAUTHENTICATED = True. Together: an anonymous
#       request gets superuser identity at the admin tier — an open admin door
#       onto the whole LMS. It was an honest dev shim, labelled as one. It is
#       also exactly what someone recovering from OX-2 would copy wholesale.
#
#   mcp_dev_urls.py                dev-only ROOT_URLCONF override that swaps
#       the LMS's hard-wired `admin/login/` React redirect for Django's plain
#       admin login. Genuinely useful when driving OAuth consent in a browser,
#       but it is a dev affordance and belongs behind an explicit setting, not
#       in the module that does the production wiring.
#
#   mcp_request_log_middleware.py  logged full Authorization headers to capture
#       evidence of the Claude.ai Bearer-token bug. Purpose-built forensics;
#       logging credentials is not something to leave switched on.
#
#   entrypoint.sh                  patched the `fs` package to survive
#       `pkg_resources.declare_namespace` on Python 3.12, for the SQLite dev
#       environment. Irrelevant on a real Tutor deployment.
# ─────────────────────────────────────────────────────────────────────────────
