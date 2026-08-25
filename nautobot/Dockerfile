# frisian-mcp demo — Nautobot
#
# Upstream Nautobot, the four apps the demo estate uses, and frisian-mcp.
# That is the whole image.
#
# The settings file is deliberately NOT baked in. docker-compose.yml mounts
# config/nautobot_config.py over Nautobot's own, so it stays readable and
# editable in the clone — that file is what the demo is actually showing.

ARG NAUTOBOT_TAG=3.2.3-py3.12
FROM ghcr.io/nautobot/nautobot:${NAUTOBOT_TAG}

ARG NAUTOBOT_VERSION=3.2.3
ARG GOLDEN_CONFIG_VERSION=3.0.7
ARG DNS_MODELS_VERSION=2.3.0
ARG BGP_MODELS_VERSION=3.1.1
ARG SSOT_VERSION=4.6.1

# Exactly one frisian-mcp source, and there is no default. A build with none
# selected must stop rather than resolve to a version nobody chose; a build
# with both must stop rather than silently pick a lane.
ARG FRISIAN_MCP_SPEC=
ARG FRISIAN_MCP_LOCAL_WHEEL=
ARG PIP_INDEX_URL=
ARG PIP_EXTRA_INDEX_URL=

# The base image ends on USER nautobot and site-packages is root-owned, so the
# installs need root. Switching back at the end is not optional.
USER root

# Always present — the directory carries a README and .gitkeep, so this cannot
# fail on a clean clone. *.whl is gitignored: a wheel is a build input.
COPY wheels/ /tmp/wheels/

# ONE pip invocation. Separate layers let a later resolve silently downgrade
# an earlier pin, and `nautobot==` is listed as a resolver guard so an app
# whose range excludes the base's Nautobot fails the build rather than
# quietly replacing the Nautobot this image is named after.
RUN set -e; \
    if [ -n "${FRISIAN_MCP_SPEC}" ] && [ -n "${FRISIAN_MCP_LOCAL_WHEEL}" ]; then \
      echo "ERROR: FRISIAN_MCP_SPEC and FRISIAN_MCP_LOCAL_WHEEL are both set. Pick one lane." >&2; exit 1; \
    fi; \
    if [ -z "${FRISIAN_MCP_SPEC}" ] && [ -z "${FRISIAN_MCP_LOCAL_WHEEL}" ]; then \
      echo "ERROR: no frisian-mcp source selected, and there is no default." >&2; \
      echo "  PyPI lane:  --build-arg FRISIAN_MCP_SPEC='frisian-mcp[usage]==<version>'" >&2; \
      echo "  Local lane: --build-arg FRISIAN_MCP_LOCAL_WHEEL=<file in nautobot/wheels/>" >&2; \
      exit 1; \
    fi; \
    pip install --no-cache-dir --only-binary=:all: \
      ${PIP_INDEX_URL:+--index-url=${PIP_INDEX_URL}} \
      ${PIP_EXTRA_INDEX_URL:+--extra-index-url=${PIP_EXTRA_INDEX_URL}} \
      "nautobot==${NAUTOBOT_VERSION}" \
      "${FRISIAN_MCP_SPEC:-/tmp/wheels/${FRISIAN_MCP_LOCAL_WHEEL}[usage]}" \
      "nautobot-golden-config==${GOLDEN_CONFIG_VERSION}" \
      "nautobot-dns-models==${DNS_MODELS_VERSION}" \
      "nautobot-bgp-models==${BGP_MODELS_VERSION}" \
      "nautobot-ssot==${SSOT_VERSION}"

ENV TIKTOKEN_CACHE_DIR=/opt/nautobot/.tiktoken-cache
RUN mkdir -p "${TIKTOKEN_CACHE_DIR}" /opt/nautobot/media /opt/nautobot/demo-state \
    && python - <<'PY' \
    && chown -R nautobot:nautobot "${TIKTOKEN_CACHE_DIR}" /opt/nautobot/media /opt/nautobot/demo-state
import os, importlib.metadata as md

# Fail the BUILD, not someone's first `docker compose up`.
for dist, want in [
    ("nautobot",             os.environ["NAUTOBOT_VERSION"]),
    ("nautobot-golden-config", os.environ["GOLDEN_CONFIG_VERSION"]),
    ("nautobot-dns-models",  os.environ["DNS_MODELS_VERSION"]),
    ("nautobot-bgp-models",  os.environ["BGP_MODELS_VERSION"]),
    ("nautobot-ssot",        os.environ["SSOT_VERSION"]),
]:
    got = md.version(dist)
    assert got == want, f"{dist} is {got}, expected {want}"

# CONTENT, not a version string. main called itself 1.1.0 without the
# hardening for most of this project, so a version pin proves nothing: a
# rehearsal against a fixed build could have published a leaky one, with
# discovery and help both looking clean. These two symbols ARE H3 + H9.
#
# Scanned as TEXT rather than imported: importing them pulls in Django models,
# which need DJANGO_SETTINGS_MODULE that does not exist at build time. An
# import here fails for a reason that has nothing to do with the wheel.
import pathlib, frisian_mcp
blob = "\n".join(
    f.read_text(errors="ignore")
    for f in pathlib.Path(frisian_mcp.__file__).parent.rglob("*.py")
)
missing = [m for m in ("_caller_rank", "entry_is_visible") if m not in blob]
assert not missing, (
    "frisian-mcp is missing the H3/H9 markers " + ", ".join(missing)
    + " — this wheel does NOT carry the permission-aware and tier lenses"
)

# Warm the BPE vocabulary into the image. Without it the first request that
# reports token usage downloads it, so the demo is slow on first use and
# simply broken offline.
#
# There is deliberately no "tiktoken absent" branch. This step used to skip
# with a printed note, which is exactly how the image came within one commit
# of shipping with token counting in its APPROXIMATE path — the skip worked
# as written and nobody read the build log. A skip is now a failure.
from frisian_mcp.usage import encoding_name
enc = encoding_name()
assert enc == "cl100k_base", f"encoding_name() is {enc!r}; the [usage] extra did not take"
import tiktoken; tiktoken.get_encoding(enc).encode("warm")
print(f"ok: nautobot {os.environ['NAUTOBOT_VERSION']}, hardening present, tiktoken {enc} warmed")
PY

USER nautobot

LABEL org.opencontainers.image.title="frisian-mcp demo — Nautobot" \
      org.opencontainers.image.source="https://github.com/Frisian-MCP/frisian-mcp-demo"
