# syntax=docker/dockerfile:1
#
# frisian-mcp-demo — Nautobot demo application image
#
#   ghcr.io/frisian-mcp/demo-nautobot:${DEMO_TAG}
#
# Thin layer over the published Nautobot image: install frisian-mcp and the
# four plugins the demo database requires, drop in the demo config, done.
#
# This deliberately does NOT reproduce the `nautobot/development/` harness
# (pip-install-at-boot, constraint file, self-repair probe, watchmedo,
# runserver --insecure). All of that exists to protect an editable /source
# install. There is no /source here — the base image ships a released
# Nautobot, and every install happens at build time.
#
# The plugin set is dictated by the demo database, not chosen. All four have
# tables in that dump; all four must be present at compatible versions or the
# restore/migrate breaks.

# ─────────────────────────────────────────────────────────────────────────────
# Base
# ─────────────────────────────────────────────────────────────────────────────
# Multi-arch verified (N1): linux/amd64 + linux/arm64 both present in the
# manifest list and both run. GHCR and Docker Hub serve byte-identical
# digests; GHCR is used so demo users hit one registry and no Docker Hub
# anonymous pull limit.
#
# The Python-qualified tag is NOT cosmetic. The bare `3.2.3` tag is Python
# 3.14, and on 3.14 pip silently backtracks `diffsync` from 2.2.3 to 2.1.0
# (diffsync 2.2.3 declares requires_python <3.14) — quietly giving
# nautobot-ssot an older diff engine than NTC tests against. frisian-mcp is
# likewise only tested on py311/312/313. Pin the Python version explicitly.
ARG NAUTOBOT_TAG=3.2.3-py3.12
FROM ghcr.io/nautobot/nautobot:${NAUTOBOT_TAG}

# An ARG declared before FROM does not survive into the build stage, so
# NAUTOBOT_TAG is re-declared here for the base.name label at the bottom.
ARG NAUTOBOT_TAG

# Must match NAUTOBOT_TAG above. Asserted at build time below rather than
# trusted — see the version-guard note on the pip layer.
ARG NAUTOBOT_VERSION=3.2.3

# ─────────────────────────────────────────────────────────────────────────────
# Pins
# ─────────────────────────────────────────────────────────────────────────────
# frisian-mcp is passed as a whole requirement specifier, not a bare version,
# so the extras can change without touching this file:
#
#   frisian-mcp==1.0.12          — latest PUBLISHED release (2026-06-17)
#   frisian-mcp[usage]==1.1.0    — once 1.1.0 is on PyPI
#
# The `usage` extra pulls tiktoken for real cl100k_base token counts. It
# exists only in the unreleased 1.1.0 tree — no published wheel provides it,
# and `pip install frisian-mcp[usage]==1.0.12` would emit a warning and
# silently install the base package. Until 1.1.0 ships, the `_usage` block
# degrades to the character-based approximation (encoding "approx-char4").
#
# ⚠️ NO DEFAULT, DELIBERATELY. DO NOT ADD ONE BACK. (S-6)
#
# This ARG previously defaulted to "frisian-mcp==1.0.12". That default was not
# merely stale, it was reachable by the one publish path that takes no inputs:
# a `git push --tags` sets publish=true unconditionally, a push event carries
# no workflow inputs, so the default was selected INSIDE the publish job and
# went straight to public GHCR with nobody reviewing a form.
#
# The artifact that produces is the one measured at N3: on 1.0.12
# FRISIAN_MCP_ROUTES does not exist, the doors 404 onto a single uncarved
# /mcp/ mount, and a read-tier token reads extras -> secret. Every control
# designed in this repo would be absent from the published image, and it would
# look healthy from outside because the front door still returns a clean 401.
#
# Unset must FAIL THE BUILD, never pick a version. The guard is below.
#
# FLOOR: a frisian-mcp release containing H3 + H9 (the permission-aware and
# tier lenses on the unknown-tool error path). That is NOT satisfied by 1.1.0
# — `main` carries the 1.1.0 version string without those fixes, so a 1.1.0
# pin would rehearse a fixed build and publish a leaky one. No such release
# exists yet, which is why this correctly fails closed today.
ARG FRISIAN_MCP_SPEC

# Wheel-only tripwire. Measured at N2: the full stack resolves to 33 packages
# with ZERO sdists on both arches, so this costs nothing today. It exists for
# the day a dependency bump reintroduces one — without it, an sdist would be
# COMPILED UNDER QEMU during the amd64 leg of a multi-arch build, turning a
# two-minute build into a long one or a mysterious failure inside emulation.
# With it, pip refuses at resolve time and says which package needs a wheel.
#
# Defaulted ON rather than set only in CI, so a local build and a CI build
# fail the same way. To unblock a build deliberately, pass an empty value:
#     docker build --build-arg PIP_ONLY_BINARY= ...
# Test PyPI lane (C3). Declared here because Docker SILENTLY IGNORES an
# undeclared build-arg and only warns — so a testpypi build against a
# Dockerfile without these would install from real PyPI and report success.
# A pre-release lane that validates the wrong artifact is worse than no lane.
# The workflow greps for both ARGs and fails closed if either is missing.
#
# Empty in the release lane, which is what keeps the index a separate axis
# from the requirement specifier: FRISIAN_MCP_SPEC stays a bare version pin in
# every lane, so the publish gate can go on rejecting specs that smuggle index
# flags. Do not merge these into that variable.
ARG PIP_INDEX_URL=
ARG PIP_EXTRA_INDEX_URL=

ARG PIP_ONLY_BINARY=:all:

ARG GOLDEN_CONFIG_VERSION=3.0.7
ARG DNS_MODELS_VERSION=2.3.0
ARG BGP_MODELS_VERSION=3.1.1
ARG SSOT_VERSION=4.6.1

# ─────────────────────────────────────────────────────────────────────────────
# Install
# ─────────────────────────────────────────────────────────────────────────────
# The base image ends on USER nautobot, and site-packages is root-owned
# (upstream copies it in without --chown), so the runtime user cannot write
# there. Switch to root for the installs and back before the image ends —
# forgetting the switch back ships a root-running demo container.
USER root

# ONE pip invocation, on purpose. Installing the plugins in separate layers
# lets a later resolve silently downgrade something an earlier one pinned.
#
# `nautobot==${NAUTOBOT_VERSION}` is listed as a resolver guard: a plugin
# whose dependency range excludes the base's Nautobot would otherwise cause
# pip to quietly uninstall and replace the Nautobot the image is named after.
# With it listed explicitly, that situation becomes a hard resolution error at
# build time instead of a surprise at runtime. This is the modern replacement
# for the harness's /tmp/nautobot-constraint.txt dance.
# Fail closed on an unset pin, with a diagnosis rather than a pip usage error.
# An empty ARG would otherwise reach pip as an empty argument and fail with
# something that does not say why.
RUN test -n "${FRISIAN_MCP_SPEC}" || { \
      echo "ERROR: build-arg FRISIAN_MCP_SPEC is required and has no default (S-6)."; \
      echo "       Pass an explicit pin, e.g.:"; \
      echo "         --build-arg FRISIAN_MCP_SPEC='frisian-mcp[usage]==<version>'"; \
      echo "       The version MUST contain H3 + H9. 1.0.12 and 1.1.0 do NOT."; \
      exit 1; \
    }

RUN pip install --no-cache-dir ${PIP_ONLY_BINARY:+--only-binary=${PIP_ONLY_BINARY}} \
      ${PIP_INDEX_URL:+--index-url=${PIP_INDEX_URL}} \
      ${PIP_EXTRA_INDEX_URL:+--extra-index-url=${PIP_EXTRA_INDEX_URL}} \
      "nautobot==${NAUTOBOT_VERSION}" \
      "${FRISIAN_MCP_SPEC}" \
      "nautobot-golden-config==${GOLDEN_CONFIG_VERSION}" \
      "nautobot-dns-models==${DNS_MODELS_VERSION}" \
      "nautobot-bgp-models==${BGP_MODELS_VERSION}" \
      "nautobot-ssot==${SSOT_VERSION}"

# Fail the BUILD, not someone's first `docker compose up`.
#
# Asserts the base image really still carries the Nautobot version this file
# claims (catches NAUTOBOT_TAG/NAUTOBOT_VERSION drift, and catches pip having
# moved Nautobot despite the guard above), and that every plugin plus
# frisian-mcp is importable and at the pinned version.
RUN python - <<PY
import importlib, importlib.metadata as md, sys

expected = {
    "nautobot": "${NAUTOBOT_VERSION}",
    "nautobot-golden-config": "${GOLDEN_CONFIG_VERSION}",
    "nautobot-dns-models": "${DNS_MODELS_VERSION}",
    "nautobot-bgp-models": "${BGP_MODELS_VERSION}",
    "nautobot-ssot": "${SSOT_VERSION}",
}
bad = []
for dist, want in expected.items():
    got = md.version(dist)
    print(f"{dist:24} {got}")
    if got != want:
        bad.append(f"{dist}: expected {want}, got {got}")

# frisian-mcp is specifier-driven, so assert presence and importability only.
print(f"{'frisian-mcp':24} {md.version('frisian-mcp')}")
importlib.import_module("frisian_mcp")

if bad:
    sys.exit("PIN DRIFT:\n  " + "\n  ".join(bad))
print("all pins verified")
PY

# ─────────────────────────────────────────────────────────────────────────────
# Runtime directories
# ─────────────────────────────────────────────────────────────────────────────
# Neither of these exists in the base image, and compose mounts a named volume
# over each. When a named volume is mounted over a path that does NOT exist in
# the image, Docker creates it root-owned and there is no image content or
# ownership for it to inherit — so the non-root runtime user cannot write to
# it. Creating them here, owned by nautobot, is what makes the volumes usable.
#
#   /opt/nautobot/media        <- media_root volume (uploads, exports)
#   /opt/nautobot/demo-state   <- demo_state volume (per-deployment SECRET_KEY)
#
# Do not delete these because "the volume creates the directory". It does, and
# it creates it owned by root.
RUN mkdir -p /opt/nautobot/media /opt/nautobot/demo-state \
    && chown nautobot:nautobot /opt/nautobot/media /opt/nautobot/demo-state

# ─────────────────────────────────────────────────────────────────────────────
# tiktoken BPE cache
# ─────────────────────────────────────────────────────────────────────────────
# Warmed at BUILD time so it is baked into the image. Without this, the first
# request that reports token usage downloads the cl100k_base vocabulary from
# the network — which means a demo that is slow on first use, and simply
# broken on an air-gapped or offline machine. Warming here removes the runtime
# egress dependency entirely.
#
# Skipped cleanly when the `usage` extra is absent (see FRISIAN_MCP_SPEC). If
# tiktoken IS installed and the warm fails, the build fails — a silently cold
# cache is exactly the failure this layer exists to prevent.
ENV TIKTOKEN_CACHE_DIR=/opt/nautobot/.tiktoken-cache
RUN mkdir -p "${TIKTOKEN_CACHE_DIR}" \
    && if python -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('tiktoken') else 1)"; then \
         python -c "import tiktoken; tiktoken.get_encoding('cl100k_base'); print('cl100k_base cached')"; \
       else \
         echo "tiktoken absent (no [usage] extra) - _usage degrades to approx-char4"; \
       fi \
    && chown -R nautobot:nautobot "${TIKTOKEN_CACHE_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Demo configuration
# ─────────────────────────────────────────────────────────────────────────────
# Replaces the base image's generated config wholesale. That file carries a
# hardcoded SECRET_KEY fallback literal, which is published in a public image
# and therefore not a secret at all; frisian's token HMAC key falls back to
# SECRET_KEY, so inheriting it would key every demo token with a world-known
# constant. See config/nautobot_config.py.
#
# Left root-owned and world-readable: the app only ever reads it, and the
# runtime user has no business rewriting its own configuration.
COPY --chown=root:root config/nautobot_config.py /opt/nautobot/nautobot_config.py

# ─────────────────────────────────────────────────────────────────────────────
# Drop privileges
# ─────────────────────────────────────────────────────────────────────────────
# Must be the last word on the subject. Entrypoint, CMD (uwsgi), exposed
# ports and HEALTHCHECK are all inherited from the base image unchanged.
USER nautobot

LABEL org.opencontainers.image.title="frisian-mcp demo — Nautobot" \
      org.opencontainers.image.description="Nautobot with frisian-mcp and a pre-seeded demo network estate. Ships published demo credentials by design; not for production." \
      org.opencontainers.image.source="https://github.com/Frisian-MCP/frisian-mcp-demo" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="ghcr.io/nautobot/nautobot:${NAUTOBOT_TAG}"
