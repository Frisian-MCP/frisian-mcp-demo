# frisian-mcp demo — Teable (Nest host, Phase 7)
#
# Upstream Teable + frisian-mcp Nest packages. That is the whole image.
#
# This is a NEST host: frisian-mcp arrives as npm packages (nestjs-test +
# core-test), not pip. See common/docs/HOST-CONTRACT.md Nest section and
# common/docs/PUBLISHING.md npm lanes.

# Pin a concrete release tag. Floating tags (`latest`, `beta`) introduce drift.
ARG TEABLE_TAG=release.2026-09-10T06-21-10Z.3025
FROM ghcr.io/teableio/teable:${TEABLE_TAG}

ARG TEABLE_TAG
ARG DEMO_TAG=dev

# ── Frisian npm packages (two lanes: registry next OR local tarballs) ──────
#
# Exactly one source, and there is no default. A build with none selected must
# stop; a build with both must stop rather than silently pick a lane.
#
# REHEARSAL / npm-next lane: exact next-channel pins (tip bar Phase 7):
#   --build-arg FRISIAN_NPM_NEXT=1
#   nestjs-test@0.0.4-rc.3  core-test@0.1.0-rc.14  sdk@^1.30.0
#
# LOCAL lane: packed .tgz under teable/.frisian/
#   --build-arg FRISIAN_LOCAL_TARBALLS=1
#   (and .frisian/*.tgz present; they are gitignored)
ARG FRISIAN_NPM_NEXT=
ARG FRISIAN_LOCAL_TARBALLS=

# Tip bar versions for Phase 7. Adjust when Frisian npm packages advance.
ARG FRISIAN_NESTJS_TEST_VERSION="0.0.4-rc.3"
ARG FRISIAN_CORE_TEST_VERSION="0.1.0-rc.14"
ARG MCP_SDK_VERSION="^1.30.0"

USER root

# Always present — the directory carries a README and .gitkeep, so this cannot
# fail on a clean clone. *.tgz is gitignored: tarballs are build inputs.
COPY .frisian/ /tmp/frisian-tarballs/

# ONE npm install. The upstream Teable image uses yarn; we stay with yarn for
# consistency. Separate installs let a later one silently downgrade an earlier
# pin.
RUN set -e; \
    if [ -n "${FRISIAN_NPM_NEXT}" ] && [ -n "${FRISIAN_LOCAL_TARBALLS}" ]; then \
      echo "ERROR: FRISIAN_NPM_NEXT and FRISIAN_LOCAL_TARBALLS are both set. Pick one lane." >&2; exit 1; \
    fi; \
    if [ -z "${FRISIAN_NPM_NEXT}" ] && [ -z "${FRISIAN_LOCAL_TARBALLS}" ]; then \
      echo "ERROR: no frisian-mcp source selected, and there is no default." >&2; \
      echo "  npm lane:   --build-arg FRISIAN_NPM_NEXT=1" >&2; \
      echo "  Local lane: --build-arg FRISIAN_LOCAL_TARBALLS=1" >&2; \
      exit 1; \
    fi; \
    cd /app; \
    if [ -n "${FRISIAN_NPM_NEXT}" ]; then \
      yarn add --exact \
        "@frisian-mcp/nestjs-test@${FRISIAN_NESTJS_TEST_VERSION}" \
        "@frisian-mcp/core-test@${FRISIAN_CORE_TEST_VERSION}" \
        "@modelcontextprotocol/sdk@${MCP_SDK_VERSION}"; \
    else \
      count=$(ls -1 /tmp/frisian-tarballs/*.tgz 2>/dev/null | wc -l); \
      if [ "$count" -eq 0 ]; then \
        echo "ERROR: FRISIAN_LOCAL_TARBALLS=1 but no .tgz found in .frisian/" >&2; \
        echo "Local tarballs are gitignored by design. Pack them first." >&2; \
        exit 1; \
      fi; \
      yarn add \
        /tmp/frisian-tarballs/frisian-mcp-nestjs-test-*.tgz \
        /tmp/frisian-tarballs/frisian-mcp-core-test-*.tgz \
        "@modelcontextprotocol/sdk@${MCP_SDK_VERSION}"; \
    fi

# Build-time assert: nestjs-test, core-test, and SDK are installed and
# resolvable. Fail the BUILD, not someone's first `docker compose up`.
RUN cd /app && node - <<'JS'
const fs = require('fs');
const path = require('path');

// Read package.json to verify installed versions
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const deps = { ...pkg.dependencies, ...pkg.devDependencies };

// Required packages must be present
const required = [
  '@frisian-mcp/nestjs-test',
  '@frisian-mcp/core-test',
  '@modelcontextprotocol/sdk'
];

for (const name of required) {
  if (!deps[name]) {
    console.error(`ERROR: ${name} not found in package.json dependencies`);
    process.exit(1);
  }
}

// SDK server/index.js must resolve (peer dependency trap from P6-2b)
try {
  require.resolve('@modelcontextprotocol/sdk/server/index.js');
  console.log('ok: @modelcontextprotocol/sdk/server/index.js resolves');
} catch (e) {
  console.error('ERROR: @modelcontextprotocol/sdk/server/index.js does not resolve');
  console.error('The peer dependency is missing. This is a measured miss from P6-2b.');
  process.exit(1);
}

console.log('ok: Frisian nestjs-test, core-test, and SDK peer are installed');
console.log(`  nestjs-test: ${deps['@frisian-mcp/nestjs-test']}`);
console.log(`  core-test: ${deps['@frisian-mcp/core-test']}`);
console.log(`  sdk: ${deps['@modelcontextprotocol/sdk']}`);
JS

USER node

LABEL org.opencontainers.image.title="frisian-mcp demo — Teable" \
      org.opencontainers.image.source="https://github.com/Frisian-MCP/frisian-mcp-demo" \
      org.opencontainers.image.description="Teable demo host with frisian-mcp Nest integration" \
      org.opencontainers.image.version="${DEMO_TAG}" \
      org.frisian.demo.host="teable" \
      org.frisian.demo.teable-tag="${TEABLE_TAG}"
