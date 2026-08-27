# frisian-mcp demo — Paperless-ngx
#
# Upstream Paperless-ngx, frisian-mcp, and the demo estate's media tree. That
# is the whole image.
#
# The settings file is deliberately NOT baked in. docker-compose.yml mounts
# config/paperless_frisian_mcp.py into the image, so it stays readable and
# editable in the clone — that file is what the demo is actually showing.
#
# NO PAPERLESS SOURCE IS VENDORED. This builds FROM the published upstream
# image. If something here appears to need a source checkout, the base image is
# wrong — raise it rather than vendoring.

ARG PAPERLESS_TAG=2.20.15
FROM ghcr.io/paperless-ngx/paperless-ngx:${PAPERLESS_TAG}

ARG PAPERLESS_VERSION=2.20.15

# Paperless pins `django~=5.2.5`. Installing frisian-mcp (`django>=5.0`) must
# not move it: a resolver that "helpfully" upgrades Django inside an image
# named after a Paperless version produces a stack nobody tested. Asserted
# after the install rather than hoped for.
ARG DJANGO_SERIES=5.2

# Exactly one frisian-mcp source, and there is no default. A build with none
# selected must stop rather than resolve to a version nobody chose; a build
# with both must stop rather than silently pick a lane.
ARG FRISIAN_MCP_SPEC=
ARG FRISIAN_MCP_LOCAL_WHEEL=
ARG PIP_INDEX_URL=
ARG PIP_EXTRA_INDEX_URL=

ARG DEMO_TAG=dev

# Always present — the directory carries a README and .gitkeep, so this cannot
# fail on a clean clone. *.whl is gitignored: a wheel is a build input.
COPY wheels/ /tmp/wheels/

# ONE install invocation. Separate layers let a later resolve silently
# downgrade an earlier pin.
#
# `uv pip install --system`, not `pip`: this base image is built on the astral
# uv image and installs its own dependencies that way. There is no guarantee
# `pip` is even present.
#
# `--no-build` refuses source distributions. On the arm64 leg of the multi-arch
# build a source dist means compiling under QEMU — minutes to hours, or a
# failure deep in a C toolchain. Everything frisian-mcp needs publishes wheels
# for both architectures; if that stops being true, this fails loudly and
# early, which is the point.
RUN set -e; \
    if [ -n "${FRISIAN_MCP_SPEC}" ] && [ -n "${FRISIAN_MCP_LOCAL_WHEEL}" ]; then \
      echo "ERROR: FRISIAN_MCP_SPEC and FRISIAN_MCP_LOCAL_WHEEL are both set. Pick one lane." >&2; exit 1; \
    fi; \
    if [ -z "${FRISIAN_MCP_SPEC}" ] && [ -z "${FRISIAN_MCP_LOCAL_WHEEL}" ]; then \
      echo "ERROR: no frisian-mcp source selected, and there is no default." >&2; \
      echo "  PyPI lane:  --build-arg FRISIAN_MCP_SPEC='frisian-mcp[usage]==<version>'" >&2; \
      echo "  Local lane: --build-arg FRISIAN_MCP_LOCAL_WHEEL=<file in paperless/wheels/>" >&2; \
      exit 1; \
    fi; \
    uv pip install --system --no-cache --no-build \
      ${PIP_INDEX_URL:+--index-url=${PIP_INDEX_URL}} \
      ${PIP_EXTRA_INDEX_URL:+--extra-index-url=${PIP_EXTRA_INDEX_URL}} \
      "${FRISIAN_MCP_SPEC:-/tmp/wheels/${FRISIAN_MCP_LOCAL_WHEEL}[usage]}" \
    && rm -rf /tmp/wheels

ENV TIKTOKEN_CACHE_DIR=/usr/src/paperless/.tiktoken-cache

ENV PAPERLESS_VERSION=${PAPERLESS_VERSION} DJANGO_SERIES=${DJANGO_SERIES}

RUN mkdir -p "${TIKTOKEN_CACHE_DIR}" /usr/src/paperless/demo-state \
    && python3 - <<'PY' \
    && chown -R paperless:paperless "${TIKTOKEN_CACHE_DIR}" /usr/src/paperless/demo-state
import os
import importlib.metadata as md

# Fail the BUILD, not someone's first `docker compose up`.
#
# Read out of the source tree rather than asked of importlib.metadata.
# Paperless is NOT an installed distribution in its own image — the upstream
# Dockerfile installs its dependencies from an exported requirements.txt and
# then COPYs ./src into place — so `md.version("paperless-ngx")` raises
# PackageNotFoundError and the guard fails for a reason that has nothing to do
# with the version.
#
# Not imported either: `import paperless` pulls in the celery app, which wants
# a settings module that does not exist at build time.
import re
import pathlib

want = os.environ["PAPERLESS_VERSION"]
_version_src = pathlib.Path("/usr/src/paperless/src/paperless/version.py").read_text()
_m = re.search(r"__version__.*?\((\d+),\s*(\d+),\s*(\d+)\)", _version_src)
assert _m, "cannot read the Paperless version out of src/paperless/version.py"
got = ".".join(_m.groups())
assert got == want, f"paperless-ngx is {got}, expected {want}"

# The resolver guard. frisian-mcp asks for django>=5.0; Paperless pins
# django~=5.2.5. If installing frisian-mcp moved Django off that series, this
# image is a Paperless release running on a Django it was never tested against
# — and everything downstream of that is someone else's confusing bug report.
series = os.environ["DJANGO_SERIES"]
dj = md.version("django")
assert dj.startswith(series + "."), (
    f"django is {dj}; installing frisian-mcp moved it off the {series}.x series "
    "Paperless pins. Do not paper over this by widening the assertion."
)

# CONTENT, not a version string. main called itself 1.1.0 without the
# hardening for most of this project, so a version pin proves nothing: a
# build against a fixed version could have published a leaky one, with
# discovery and help both looking clean. These two symbols ARE H3 + H9.
#
# Scanned as TEXT rather than imported: importing them pulls in Django models,
# which need DJANGO_SETTINGS_MODULE that does not exist at build time. An
# import here fails for a reason that has nothing to do with the wheel.
import frisian_mcp

blob = "\n".join(
    f.read_text(errors="ignore")
    for f in pathlib.Path(frisian_mcp.__file__).parent.rglob("*.py")
)
missing = [m for m in ("_caller_rank", "entry_is_visible") if m not in blob]
assert not missing, (
    "frisian-mcp is missing the H3/H9 markers " + ", ".join(missing)
    + " — this wheel does NOT carry the permission-aware and tier lenses"
)

# FRISIAN_MCP_ROUTES is the whole per-route model, and config/
# paperless_frisian_mcp.py is nothing but a route model. On a package that
# predates it the setting is not rejected and not warned about — it is simply
# never read, the three doors never mount, and the demo silently becomes one
# undifferentiated /mcp/ endpoint that still answers 401 to anonymous callers.
# That failure is invisible from the front door, so it is asserted here.
assert "FRISIAN_MCP_ROUTES" in blob, (
    "frisian-mcp does not know about FRISIAN_MCP_ROUTES — this build predates "
    "the per-route permission model and the three demo doors would not mount"
)

# Warm the BPE vocabulary into the image. Without it the first request that
# reports token usage downloads it, so the demo is slow on first use and
# simply broken offline.
#
# There is deliberately no "tiktoken absent" branch. A skip that prints a note
# is how an image ships with token counting silently in its APPROXIMATE path
# and nobody reads the build log. A skip is a failure.
from frisian_mcp.usage import encoding_name

enc = encoding_name()
assert enc == "cl100k_base", f"encoding_name() is {enc!r}; the [usage] extra did not take"
import tiktoken

tiktoken.get_encoding(enc).encode("warm")
print(f"ok: paperless-ngx {want}, django {dj}, hardening present, tiktoken {enc} warmed")
PY

# ---------------------------------------------------------------------------
# The demo estate's media tree.
#
# Paperless's estate is not just database rows. Every document has an original
# file, a thumbnail and (for OCR'd PDFs) an archive copy on disk, and a
# database that references files which are not there is not a demo — it is a
# broken instance where every download 404s.
#
# So BOTH images carry half of one artifact: the db image carries the SQL, this
# one carries the media the SQL points at. That is a second, independent reason
# the two images must never be pulled at different tags.
#
# The tarball is NOT in git (it is a build artifact, and a large binary one).
# `estate/` ships a .gitkeep so this COPY works on a clean clone; a build
# without the artifact produces an image that boots and shows zero documents,
# which the restore script below says out loud rather than leaving you to
# discover.
# ---------------------------------------------------------------------------
COPY --chown=paperless:paperless estate/ /usr/src/paperless/demo-estate/

# The settings module, baked AND mounted.
#
# Baked so the image is self-contained and `docker run` on it does something
# sensible. Mounted over, by docker-compose.yml, so the copy a user reads and
# edits in their clone is the copy the container actually loads. The two are
# the same file; if they ever disagree, the mount wins, which is the intent.
#
# It lands beside Paperless's own `paperless/` package on the src path, which
# is what makes `DJANGO_SETTINGS_MODULE=paperless_frisian_mcp` importable.
COPY --chown=paperless:paperless \
     config/paperless_frisian_mcp.py /usr/src/paperless/src/paperless_frisian_mcp.py

# Restores the media tree on EVERY container start. Root-owned and not
# world-writable, because paperless's init-custom-init refuses to run scripts
# that are neither — it prints a tampering warning and skips the whole
# directory, which would leave the estate silently absent.
COPY --chown=root:root --chmod=0755 \
     scripts/10-restore-demo-estate.sh /custom-cont-init.d/10-restore-demo-estate.sh

LABEL org.opencontainers.image.title="frisian-mcp demo — Paperless-ngx" \
      org.opencontainers.image.description="Paperless-ngx with frisian-mcp and a pre-built demo estate. Ships published demo credentials by design." \
      org.opencontainers.image.source="https://github.com/Frisian-MCP/frisian-mcp-demo" \
      org.opencontainers.image.version="${DEMO_TAG}" \
      org.frisian.demo.host="paperless"
