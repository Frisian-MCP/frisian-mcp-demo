#!/usr/bin/env bash
#
# Publish the Teable demo image PAIR to GHCR.
#
#   ./publish.sh              build + verify locally, push NOTHING (default)
#   ./publish.sh --push       build, push both images, verify the manifests
#
# Publishing is deliberately not the default. Everything up to the push runs
# either way, so a dry run tells you whether the real one would work.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE ONE VALUE THAT CHANGES WHEN FRISIAN NPM PACKAGES ARE RELEASED
# ─────────────────────────────────────────────────────────────────────────────
#
# Nest hosts use npm packages (nestjs-test + core-test), not pip. Two lanes:
#
#   REHEARSAL / local tarballs:
#     FRISIAN_SOURCE="local-tarballs"
#     (requires .frisian/*.tgz present; they are gitignored)
#
#   npm-next registry:
#     FRISIAN_SOURCE="npm-next:@frisian-mcp/nestjs-test@0.0.4-rc.3,@frisian-mcp/core-test@0.1.0-rc.14"
#
# When immutable non-rc npm packages exist, change to:
#     FRISIAN_SOURCE="npm-release:@frisian-mcp/nestjs-test@1.0.0,@frisian-mcp/core-test@1.0.0"
#
# and the lane, tag suffix, and provenance labels follow automatically.
#
# Tip bar for Phase 7:
FRISIAN_SOURCE="npm-next:@frisian-mcp/nestjs-test@0.0.4-rc.3,@frisian-mcp/core-test@0.1.0-rc.14"
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REGISTRY="ghcr.io/frisian-mcp"
APP_IMAGE="${REGISTRY}/demo-teable"
DB_IMAGE="${REGISTRY}/demo-teable-db"
PLATFORMS="linux/amd64,linux/arm64"

# Base version of the DEMO, not of anything inside it. A pre-release suffix is
# appended automatically below when the contents warrant it — never by hand.
DEMO_VERSION="${DEMO_VERSION:-v0.1.0-rc.1}"

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PUSH=false
[ "${1:-}" = "--push" ] && PUSH=true

# ── Derive everything from the one value ─────────────────────────────────────
case "$FRISIAN_SOURCE" in
  local-tarballs)
    LANE="rehearsal"
    DEMO_TAG="${DEMO_VERSION}"  # Already -rc in DEMO_VERSION for Phase 7 tip
    BUILD_TARBALLS=1
    BUILD_NPM_NEXT=""
    # Verify tarballs exist
    if [ ! -f .frisian/frisian-mcp-nestjs-test-*.tgz ] || \
       [ ! -f .frisian/frisian-mcp-core-test-*.tgz ]; then
      echo "ERROR: .frisian/*.tgz tarballs not found." >&2
      echo "Local tarballs are gitignored by design. Pack them first:" >&2
      echo "  npm pack @frisian-mcp/nestjs-test" >&2
      echo "  npm pack @frisian-mcp/core-test" >&2
      echo "  cp *.tgz teable/.frisian/" >&2
      exit 1
    fi
    PROVENANCE="local tarballs ($(ls .frisian/*.tgz | wc -l | tr -d ' ') files)"
    ;;
  npm-next:*)
    SPEC="${FRISIAN_SOURCE#npm-next:}"
    LANE="npm-next"
    DEMO_TAG="${DEMO_VERSION}"  # Already -rc for tip
    BUILD_TARBALLS=""
    BUILD_NPM_NEXT=1
    PROVENANCE="npm next ${SPEC}"
    ;;
  npm-release:*)
    SPEC="${FRISIAN_SOURCE#npm-release:}"
    LANE="release"
    DEMO_TAG="${DEMO_VERSION}"
    BUILD_TARBALLS=""
    BUILD_NPM_NEXT=""
    PROVENANCE="npm release ${SPEC}"
    ;;
  *)
    echo "ERROR: FRISIAN_SOURCE must start with 'local-tarballs', 'npm-next:', or 'npm-release:'." >&2
    exit 1 ;;
esac

echo "── plan ─────────────────────────────────────────────"
echo "  lane        ${LANE}"
echo "  frisian-mcp ${PROVENANCE}"
echo "  tag         ${DEMO_TAG}          (BOTH images, lockstep)"
echo "  platforms   ${PLATFORMS}"
echo "  push        ${PUSH}"
echo "─────────────────────────────────────────────────────"

# The golden artifact is gitignored, so a fresh clone will not have it.
# NOTE: For Phase 7 tip work, demo.sql.gz may not exist yet. Document the gap
# in README.md if this check fails. Uncomment when golden dump is available.
# [ -f db/demo.sql.gz ] || {
#   echo "ERROR: db/demo.sql.gz not found — the db image would be empty." >&2
#   exit 1; }

LABELS=(
  --label "org.opencontainers.image.source=https://github.com/Frisian-MCP/frisian-mcp-demo"
  --label "org.opencontainers.image.version=${DEMO_TAG}"
  --label "org.frisian.demo.frisian-mcp-source=${PROVENANCE}"
  --label "org.frisian.demo.lane=${LANE}"
  --label "org.frisian.demo.host=teable"
)

OUTPUT="--output=type=cacheonly"
$PUSH && OUTPUT="--push"

# Both images, one tag, one invocation each, back to back. They are two halves
# of one artifact: a dump is welded to the migration state that produced it, so
# a partial publish is the mixed state the lockstep tag exists to prevent.
# Preflight: refuse to build if we cannot push (same credential check as nautobot)
if $PUSH; then
  _store="$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.docker/config.json"))).get("credsStore",""))' 2>/dev/null || true)"
  _have_ghcr=false
  if [ -n "$_store" ] && command -v "docker-credential-${_store}" >/dev/null 2>&1; then
    "docker-credential-${_store}" list 2>/dev/null | grep -q 'ghcr\.io' && _have_ghcr=true
  else
    grep -q '"ghcr\.io"' ~/.docker/config.json 2>/dev/null && _have_ghcr=true
  fi
  if ! $_have_ghcr; then
    echo "ERROR: not logged in to ghcr.io — refusing to build." >&2
    echo "       buildx would fall back to an anonymous push and fail at export." >&2
    echo >&2
    echo "       docker login ghcr.io -u <github-username>" >&2
    echo "       (password = a GitHub PAT with the write:packages scope)" >&2
    exit 1
  fi
  echo "  ghcr.io   credential found"
fi

echo "==> db image"
docker buildx build $OUTPUT --platform "$PLATFORMS" \
  "${LABELS[@]}" \
  --build-arg "DEMO_TAG=${DEMO_TAG}" \
  -t "${DB_IMAGE}:${DEMO_TAG}" -f db/Dockerfile .

echo "==> app image"
docker buildx build $OUTPUT --platform "$PLATFORMS" \
  "${LABELS[@]}" \
  --build-arg "DEMO_TAG=${DEMO_TAG}" \
  --build-arg "FRISIAN_LOCAL_TARBALLS=${BUILD_TARBALLS}" \
  --build-arg "FRISIAN_NPM_NEXT=${BUILD_NPM_NEXT}" \
  -t "${APP_IMAGE}:${DEMO_TAG}" -f Dockerfile .

if ! $PUSH; then
  echo
  echo "Dry run complete — nothing was pushed."
  echo "Re-run with --push to publish."
  exit 0
fi

# Verify the guarantee rather than treating a successful push as proof of it.
echo "==> verifying both manifests"
for img in "$APP_IMAGE" "$DB_IMAGE"; do
  out="$(docker buildx imagetools inspect "${img}:${DEMO_TAG}")"
  for arch in amd64 arm64; do
    printf '%s' "$out" | grep -q "linux/${arch}" \
      || { echo "ERROR: ${img}:${DEMO_TAG} is missing linux/${arch}" >&2; exit 1; }
  done
  echo "  ok  ${img}:${DEMO_TAG}  (amd64 + arm64)"
done

# Pin .env to the tag we just published.
for f in .env .env.example; do
  [ -f "$f" ] || continue
  if grep -q '^DEMO_TAG=' "$f"; then
    tmp="$(mktemp)"
    sed "s|^DEMO_TAG=.*|DEMO_TAG=${DEMO_TAG}|" "$f" > "$tmp" && mv "$tmp" "$f"
    echo "  pinned ${f} -> DEMO_TAG=${DEMO_TAG}"
  fi
done

cat <<EOS

── published ────────────────────────────────────────
  ${APP_IMAGE}:${DEMO_TAG}
  ${DB_IMAGE}:${DEMO_TAG}

FIRST PUBLISH — the packages stay CLOSED. Manual steps:

  1. LEAVE BOTH PACKAGES PRIVATE. Do NOT flip them public.
     Verify BOTH read Private at https://github.com/orgs/Frisian-MCP/packages

  2. Restrict WRITE to approved people (separate from visibility).

  3. Verify LOGGED OUT (inverted while private — both pulls MUST FAIL):
       docker logout ghcr.io
       docker pull ${APP_IMAGE}:${DEMO_TAG}     # MUST FAIL
       docker pull ${DB_IMAGE}:${DEMO_TAG}      # MUST FAIL

  4. COMMIT the pinned .env — publish.sh just rewrote DEMO_TAG.

Then, from a fresh clone:
    cd teable && DEMO_TAG=${DEMO_TAG} docker compose up

See common/docs/PUBLISHING.md for the full runbook.
EOS
