#!/usr/bin/env bash
#
# Publish the Nautobot demo image PAIR to GHCR.
#
#   ./publish.sh              build + verify locally, push NOTHING (default)
#   ./publish.sh --push       build, push both images, verify the manifests
#
# Publishing is deliberately not the default. Everything up to the push runs
# either way, so a dry run tells you whether the real one would work.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE ONE VALUE THAT CHANGES WHEN frisian-mcp IS RELEASED
# ─────────────────────────────────────────────────────────────────────────────
#
# Today the demo ships a locally built, pre-release frisian-mcp, because no
# release carrying the H3/H9 hardening exists on PyPI yet. That is the only
# reason. When one does, change this single line:
#
#     FRISIAN_MCP_SOURCE="pypi:frisian-mcp[usage]==1.1.0"
#
# and everything else follows automatically — the lane, the build args, the
# pre-release suffix on the tag, and the provenance labels. Nothing else in
# this file, the workflow, or the compose files needs editing.
#
FRISIAN_MCP_SOURCE="local-wheel:frisian_mcp-1.1.0-py3-none-any.whl"
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REGISTRY="ghcr.io/frisian-mcp"
APP_IMAGE="${REGISTRY}/demo-nautobot"
DB_IMAGE="${REGISTRY}/demo-nautobot-db"
PLATFORMS="linux/amd64,linux/arm64"

# Base version of the DEMO, not of anything inside it. A pre-release suffix is
# appended automatically below when the contents warrant it — never by hand.
DEMO_VERSION="${DEMO_VERSION:-v0.1.0}"

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PUSH=false
[ "${1:-}" = "--push" ] && PUSH=true

# ── Derive everything from the one value ─────────────────────────────────────
case "$FRISIAN_MCP_SOURCE" in
  local-wheel:*)
    WHEEL="${FRISIAN_MCP_SOURCE#local-wheel:}"
    SPEC=""
    LANE="rehearsal"
    # The suffix is not decoration. This image carries a frisian-mcp that
    # nobody can `pip install`, and a tag that does not say so invites the next
    # person to treat it as a release build.
    DEMO_TAG="${DEMO_VERSION}-pre"
    [ -f "wheels/${WHEEL}" ] || {
      echo "ERROR: wheels/${WHEEL} not found." >&2
      echo "Rehearsal wheels are gitignored by design. Build it from a clean" >&2
      echo "origin/main export first (see wheels/README.md)." >&2
      exit 1; }
    WHEEL_SHA="$(shasum -a 256 "wheels/${WHEEL}" | cut -d' ' -f1)"
    PROVENANCE="local wheel ${WHEEL} sha256:${WHEEL_SHA}"
    ;;
  pypi:*)
    SPEC="${FRISIAN_MCP_SOURCE#pypi:}"
    WHEEL=""
    LANE="release"
    DEMO_TAG="${DEMO_VERSION}"
    WHEEL_SHA=""
    PROVENANCE="pypi ${SPEC}"
    ;;
  *)
    echo "ERROR: FRISIAN_MCP_SOURCE must start with 'local-wheel:' or 'pypi:'." >&2
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
[ -f db/demo.sql.gz ] || {
  echo "ERROR: db/demo.sql.gz not found — the db image would be empty." >&2
  exit 1; }

LABELS=(
  --label "org.opencontainers.image.source=https://github.com/Frisian-MCP/frisian-mcp-demo"
  --label "org.opencontainers.image.version=${DEMO_TAG}"
  # Provenance travels as a label rather than in the tag: a re-cut that changes
  # neither component version would have nowhere to go in a tag-encoded scheme.
  --label "org.frisian.demo.frisian-mcp-source=${PROVENANCE}"
  --label "org.frisian.demo.lane=${LANE}"
)
[ -n "$WHEEL_SHA" ] && LABELS+=( --label "org.frisian.demo.frisian-mcp-wheel-sha256=${WHEEL_SHA}" )

OUTPUT="--output=type=cacheonly"
$PUSH && OUTPUT="--push"

# Both images, one tag, one invocation each, back to back. They are two halves
# of one artifact: a dump is welded to the migration state that produced it, so
# a partial publish is the mixed state the lockstep tag exists to prevent.
echo "==> db image"
docker buildx build $OUTPUT --platform "$PLATFORMS" \
  "${LABELS[@]}" \
  --build-arg "DEMO_TAG=${DEMO_TAG}" \
  -t "${DB_IMAGE}:${DEMO_TAG}" -f db/Dockerfile .

echo "==> app image"
docker buildx build $OUTPUT --platform "$PLATFORMS" \
  "${LABELS[@]}" \
  --build-arg "DEMO_TAG=${DEMO_TAG}" \
  --build-arg "FRISIAN_MCP_SPEC=${SPEC}" \
  --build-arg "FRISIAN_MCP_LOCAL_WHEEL=${WHEEL}" \
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

cat <<EOS

── published ────────────────────────────────────────
  ${APP_IMAGE}:${DEMO_TAG}
  ${DB_IMAGE}:${DEMO_TAG}

FIRST PUBLISH ONLY — two manual steps, and the demo is unusable without them:

  1. GHCR package visibility is NOT inherited from repository visibility, and
     these are TWO SEPARATE packages with independent settings. Flip BOTH to
     public at https://github.com/orgs/Frisian-MCP/packages
     Missing the db package gives a demo that pulls the app and then fails on
     the database with a confusing permissions error.

  2. Verify LOGGED OUT, from a machine with no local cache:
       docker logout ghcr.io
       docker pull ${APP_IMAGE}:${DEMO_TAG}
       docker pull ${DB_IMAGE}:${DEMO_TAG}
     Publishing from an account that can already pull private packages hides a
     visibility mistake completely. This is the step people skip.

  Then, from a fresh clone:
       cd nautobot && DEMO_TAG=${DEMO_TAG} docker compose up

See common/docs/PUBLISHING.md for the full runbook.
EOS
