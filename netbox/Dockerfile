# frisian-mcp demo — NetBox
#
# Upstream NetBox, frisian-mcp, and the plugin wrapper that mounts it. That is
# the whole image.
#
# The settings file is deliberately NOT baked in. docker-compose.yml mounts
# config/frisian_mcp.py over netbox-docker's own `extra.py`, so it stays
# readable and editable in the clone — that file is what the demo is showing.
#
# NO NETBOX SOURCE IS VENDORED. This builds FROM the published upstream image.

ARG NETBOX_TAG=v4.6.2
FROM docker.io/netboxcommunity/netbox:${NETBOX_TAG}

ARG NETBOX_VERSION=4.6.2

# NetBox 4.6 ships Django 6.0. frisian-mcp asks for django>=5.0 with no upper
# bound, so a resolver is free to move Django underneath a NetBox release that
# pins it — asserted after the install rather than hoped for.
ARG DJANGO_SERIES=6.0

# Exactly one frisian-mcp source, and there is no default. A build with none
# selected must stop rather than resolve to a version nobody chose; a build
# with both must stop rather than silently pick a lane.
ARG FRISIAN_MCP_SPEC=
ARG FRISIAN_MCP_LOCAL_WHEEL=
ARG PIP_INDEX_URL=
ARG PIP_EXTRA_INDEX_URL=
ARG DEMO_TAG=dev

USER root

# Always present — the directory carries a README and .gitkeep, so this cannot
# fail on a clean clone. *.whl is gitignored: a wheel is a build input.
COPY wheels/ /tmp/wheels/
# The plugin wrapper. Baked rather than mounted: NetBox reads PLUGINS at
# startup from INSTALLED_APPS, so the app must be importable before Django
# boots.
COPY plugin/ /tmp/plugin/

# ONE install invocation. Separate layers let a later resolve silently
# downgrade an earlier pin.
#
# `uv`, not `pip`: this image ships uv and has NO pip at all, in the venv or on
# PATH. `--python` points uv at the venv NetBox actually runs from; installing
# to the system interpreter would put the package somewhere NetBox never looks.
RUN set -e; \
    if [ -n "${FRISIAN_MCP_SPEC}" ] && [ -n "${FRISIAN_MCP_LOCAL_WHEEL}" ]; then \
      echo "ERROR: FRISIAN_MCP_SPEC and FRISIAN_MCP_LOCAL_WHEEL are both set. Pick one lane." >&2; exit 1; \
    fi; \
    if [ -z "${FRISIAN_MCP_SPEC}" ] && [ -z "${FRISIAN_MCP_LOCAL_WHEEL}" ]; then \
      echo "ERROR: no frisian-mcp source selected, and there is no default." >&2; \
      echo "  PyPI lane:  --build-arg FRISIAN_MCP_SPEC='frisian-mcp[usage]==<version>'" >&2; \
      echo "  Local lane: --build-arg FRISIAN_MCP_LOCAL_WHEEL=<file in netbox/wheels/>" >&2; \
      exit 1; \
    fi; \
    uv pip install --python /opt/netbox/venv/bin/python --no-cache \
      ${PIP_INDEX_URL:+--index-url=${PIP_INDEX_URL}} \
      ${PIP_EXTRA_INDEX_URL:+--extra-index-url=${PIP_EXTRA_INDEX_URL}} \
      "${FRISIAN_MCP_SPEC:-/tmp/wheels/${FRISIAN_MCP_LOCAL_WHEEL}[usage]}" \
      /tmp/plugin \
    && rm -rf /tmp/wheels /tmp/plugin

ENV TIKTOKEN_CACHE_DIR=/opt/netbox/.tiktoken-cache
ENV NETBOX_VERSION=${NETBOX_VERSION} DJANGO_SERIES=${DJANGO_SERIES}

RUN mkdir -p "${TIKTOKEN_CACHE_DIR}" /opt/netbox/demo-state \
    && /opt/netbox/venv/bin/python - <<'PY' \
    && chown -R netbox:root "${TIKTOKEN_CACHE_DIR}" /opt/netbox/demo-state
import os
import re
import pathlib
import importlib.metadata as md

# Fail the BUILD, not someone's first `docker compose up`.
#
# Read out of the source tree rather than asked of importlib.metadata: NetBox
# is not installed as a distribution in its own image, so a metadata lookup
# fails for a reason that has nothing to do with the version.
# The version lives in release.yaml. settings.py only derives it
# (`VERSION = RELEASE.full_version`), so there is no literal to match there —
# a regex against settings.py finds nothing and fails for the wrong reason.
want = os.environ["NETBOX_VERSION"]
src = pathlib.Path("/opt/netbox/netbox/release.yaml").read_text(errors="ignore")
m = re.search(r'version:\s*"?([0-9]+\.[0-9]+\.[0-9]+)', src)
assert m, "cannot read NetBox's version out of /opt/netbox/netbox/release.yaml"
assert m.group(1) == want, f"netbox is {m.group(1)}, expected {want}"

# The resolver guard. NetBox 4.6 pins Django 6.0; frisian-mcp asks for >=5.0
# with no ceiling, so nothing stops a resolver moving it. An image named after
# a NetBox release running a Django that release never saw is somebody else's
# confusing bug report.
series = os.environ["DJANGO_SERIES"]
dj = md.version("django")
assert dj.startswith(series + "."), (
    f"django is {dj}; installing frisian-mcp moved it off the {series}.x series "
    "NetBox pins. Do not paper over this by widening the assertion."
)

# CONTENT, not a version string. A version pin proves nothing: main called
# itself 1.1.0 without the hardening for most of this project. These symbols
# ARE the permission-aware and tier lenses.
#
# Scanned as TEXT rather than imported: importing pulls in Django models, which
# need settings that do not exist at build time.
import frisian_mcp

blob = "\n".join(
    f.read_text(errors="ignore")
    for f in pathlib.Path(frisian_mcp.__file__).parent.rglob("*.py")
)
missing = [s for s in ("_caller_rank", "entry_is_visible", "FRISIAN_MCP_ROUTES") if s not in blob]
assert not missing, (
    "frisian-mcp is missing " + ", ".join(missing)
    + " — this wheel does not carry the hardening or the per-route model"
)

# The plugin wrapper has to be importable before Django boots, because NetBox
# reads PLUGINS at startup. A missing wrapper surfaces as an opaque
# ImproperlyConfigured on someone's first `up`; catch it here instead.
import frisian_mcp_netbox  # noqa: F401

# Warm the BPE vocabulary into the image. Without it the first request that
# reports token usage downloads it, so the demo is slow on first use and
# broken offline. There is deliberately no "tiktoken absent" branch: a skip
# that prints a note is how an image ships with token counting silently in its
# APPROXIMATE path and nobody reads the build log.
from frisian_mcp.usage import encoding_name

enc = encoding_name()
assert enc == "cl100k_base", f"encoding_name() is {enc!r}; the [usage] extra did not take"
import tiktoken

tiktoken.get_encoding(enc).encode("warm")
print(f"ok: netbox {want}, django {dj}, hardening present, plugin importable, tiktoken {enc} warmed")
PY

LABEL org.opencontainers.image.title="frisian-mcp demo — NetBox" \
      org.opencontainers.image.description="NetBox with frisian-mcp and a pre-built network estate. Ships published demo credentials by design." \
      org.opencontainers.image.source="https://github.com/Frisian-MCP/frisian-mcp-demo" \
      org.opencontainers.image.version="${DEMO_TAG}" \
      org.frisian.demo.host="netbox"
