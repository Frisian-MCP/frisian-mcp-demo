#!/usr/bin/env bash
#
# Stage the two wheels the Tutor plugin's Dockerfile patch installs.
#
#   ./stage-wheels.sh /path/to/frisian_mcp-<version>-py3-none-any.whl
#
# A Dockerfile `COPY` can only see files inside the image build context, and
# Tutor's openedx build context is `$TUTOR_ROOT/env/build/openedx`. So both
# wheels have to be put there before `tutor images build openedx`, and they
# have to be put there AGAIN after any `tutor config save` — that command
# re-renders the env, and anything staged into it is a build input rather than
# something Tutor knows to preserve.
#
# WHY WHEELS AND NOT `pip install frisian-mcp`
#
#   frisian-mcp          the version carrying the per-route model and the
#                        H3/H9 hardening is not on PyPI; the newest published
#                        is 1.0.12.
#   openedx-frisian-mcp  the install doc says a reference plugin app ships in
#                        the package repo. It does not (finding OX-2). This
#                        builds the ported one in ./plugin/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WHEEL="${1:-}"
if [ -z "$WHEEL" ]; then
  echo "usage: $0 <path-to-frisian_mcp-*.whl>" >&2
  echo >&2
  echo "Build one from a clean origin/main export — never from a working" >&2
  echo "checkout's dist/, which is routinely stale and may carry another" >&2
  echo "branch's uncommitted work:" >&2
  echo >&2
  echo "  mkdir -p /tmp/fm && git -C <frisian-mcp> archive origin/main | tar -x -C /tmp/fm" >&2
  echo "  python -m pip wheel --no-deps --wheel-dir /tmp/wheels /tmp/fm" >&2
  exit 2
fi
[ -f "$WHEEL" ] || { echo "ERROR: no such wheel: $WHEEL" >&2; exit 1; }

: "${TUTOR_ROOT:?TUTOR_ROOT must be set — it is where the build context lives}"
CONTEXT="${TUTOR_ROOT}/env/build/openedx"
[ -d "$CONTEXT" ] || {
  echo "ERROR: ${CONTEXT} does not exist." >&2
  echo "Run \`tutor config save\` first so the env is generated." >&2
  exit 1; }

STAGE="${CONTEXT}/frisian-wheels"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# The plugin app, built fresh. It is small and changes more often than the
# package, so it is rebuilt rather than cached.
echo "==> building the Open edX plugin app"
python3 -m pip wheel --quiet --no-deps --wheel-dir "$STAGE" "${HERE}/plugin"

echo "==> staging frisian-mcp"
cp "$WHEEL" "$STAGE/"

echo
echo "── staged into ${STAGE} ─────────────────────────────"
for f in "$STAGE"/*.whl; do
  printf '  %-52s %s bytes\n' "$(basename "$f")" "$(wc -c < "$f" | tr -d ' ')"
done
cat <<EOS

Next:
  tutor images build openedx      # REQUIRED — the plugin patches the Dockerfile
  tutor local start -d

Re-run this script after any \`tutor config save\`: that re-renders env/ and
the staged wheels do not survive it.
EOS
