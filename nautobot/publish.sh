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
# Preflight: refuse to build if we cannot push.
#
# Without this, a missing ghcr.io credential surfaces AFTER both multi-arch
# builds, as "failed to fetch anonymous token ... 403 Forbidden" during layer
# export -- minutes of work and an error naming neither the cause nor the fix.
# buildx falls back to ANONYMOUS when it finds no credential, so the 403 is the
# registry refusing an anonymous push, not a permissions problem on the account.
#
# Checked against the credential store rather than ~/.docker/config.json: with
# a credsStore configured, config.json carries no auths entry even when logged
# in, so reading the file would report a false negative.
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

# Pin .env to the tag we just published.
#
# publish.sh is the ONLY thing that knows the -pre suffix; .env is TRACKED and
# ships in every clone, so it is what a zero-flag `docker compose up` resolves.
# Nothing pinned the two equal, and a dry run cannot catch the drift because it
# never exercises clone -> up. Publishing v0.1.0-pre while every clone asks for
# v0.1.0 breaks the 60-second quickstart on its first command, for both images.
#
# Writing it here means the commit that publishes is the commit that points at
# what was published.
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

FIRST PUBLISH — the packages stay CLOSED. Two manual steps:

  1. LEAVE BOTH PACKAGES PRIVATE. Do NOT flip them public.
     Ruled 2026-08-24: closed until our own testing is done. GHCR visibility
     is NOT inherited from repository visibility, and these are TWO SEPARATE
     packages with independent settings — so confirm BOTH read Private at
     https://github.com/orgs/Frisian-MCP/packages rather than assuming.

     Restrict WRITE to approved people. Visibility and write are SEPARATE
     controls: a public package is already read-only to the world (there is
     no anonymous push), so making it public later does not restrict writes
     and never did. Check every write path, not just the obvious one:
       - explicit package role assignments (read / write / admin)
       - INHERITED repository access — repo write can become package write
       - workflow GITHUB_TOKEN with `packages: write`
       - PATs carrying `write:packages`

  2. Verify LOGGED OUT — and while private the check is INVERTED:
       docker logout ghcr.io
       docker pull ${APP_IMAGE}:${DEMO_TAG}     # MUST FAIL
       docker pull ${DB_IMAGE}:${DEMO_TAG}      # MUST FAIL
     A private package an anonymous user CAN pull is the failure this policy
     exists to prevent, and you would never see it from an authenticated
     machine. Then pull as an approved account and confirm both succeed.

  3. COMMIT the pinned .env — publish.sh just rewrote DEMO_TAG to match what
     was published. Uncommitted, a fresh clone still asks for the old tag.

  Then, from a fresh clone:
       cd nautobot && DEMO_TAG=${DEMO_TAG} docker compose up

See common/docs/PUBLISHING.md for the full runbook.
EOS
