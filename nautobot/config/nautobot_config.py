# ============================================================================
# PLACEHOLDER — NOT THE DEMO CONFIG. Replaced by task N3.
# ============================================================================
# This file exists only so the Dockerfile's COPY layer can be build-verified
# before N3 writes the real locked-posture configuration. It is deliberately
# minimal and it is NOT safe to publish.
#
# Missing, and required by N3:
#   - locked posture (token required, nothing visible unauthenticated)
#   - PLUGINS list for the four demo plugins
#   - SECRET_KEY generated per deployment, persisted to /opt/nautobot/demo-state
#   - FRISIAN_MCP_HMAC_KEY pinned to the published demo constant
#   - must pass `nautobot-server check --deploy`, which the base entrypoint
#     runs on every start and hard-exits on
# ============================================================================
import os

from nautobot.core.settings import *  # noqa: F401,F403
from nautobot.core.settings_funcs import parse_redis_connection  # noqa: F401

ALLOWED_HOSTS = os.getenv("NAUTOBOT_ALLOWED_HOSTS", "localhost 127.0.0.1 [::1]").split(" ")

DATABASES = {
    "default": {
        "NAME": os.getenv("NAUTOBOT_DB_NAME", "nautobot"),
        "USER": os.getenv("NAUTOBOT_DB_USER", "nautobot"),
        "PASSWORD": os.getenv("NAUTOBOT_DB_PASSWORD", ""),
        "HOST": os.getenv("NAUTOBOT_DB_HOST", "db"),
        "PORT": os.getenv("NAUTOBOT_DB_PORT", "5432"),
        "CONN_MAX_AGE": int(os.getenv("NAUTOBOT_DB_TIMEOUT", "300")),
        "ENGINE": "django.db.backends.postgresql",
    }
}

# No literal fallback, by design — see N1 finding F4. The base image's own
# config defaults SECRET_KEY to a published constant; never inherit that shape.
SECRET_KEY = os.environ["NAUTOBOT_SECRET_KEY"]
