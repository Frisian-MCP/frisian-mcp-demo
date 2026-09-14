# Pre-seeded PostgreSQL for the Teable demo host.
#
# Deliberately trivial, and it must stay that way.
#
# This image bakes SQL TEXT, never a pre-initialised PGDATA. A data directory
# is architecture-sensitive, which would drag Postgres startup and provisioning
# through QEMU on the arm64 leg of the multi-arch build. SQL text is
# architecture-independent, so the seed runs once natively on amd64 and both
# architectures reuse it — which reduces this image's build to a file copy.
#
# That is why the C-track is cheap. Do not "optimise" it into a baked data
# directory.
#
# Build context is the HOST directory (teable/), not db/:
#   docker build -f db/Dockerfile teable/

# Teable officially supports PostgreSQL 15. Pin the major only.
ARG POSTGRES_MAJOR=15
FROM postgres:${POSTGRES_MAJOR}

ARG POSTGRES_MAJOR
ARG DEMO_TAG=dev

LABEL org.opencontainers.image.source="https://github.com/Frisian-MCP/frisian-mcp-demo"
LABEL org.opencontainers.image.title="frisian-mcp demo — Teable database"
LABEL org.opencontainers.image.description="Pre-seeded PostgreSQL carrying the Teable demo estate. Ships published demo credentials by design."
LABEL org.opencontainers.image.version="${DEMO_TAG}"
LABEL org.frisian.demo.host="teable"
LABEL org.frisian.demo.postgres-major="${POSTGRES_MAJOR}"

# The golden dump. NOT in git — CI injects it here before building (see the
# seed job in .github/workflows/build-teable.yml), and .gitignore excludes
# it. If this COPY fails, the artifact is missing.
#
# For tip/rehearsal work before a golden dump exists: document the gap in
# README.md and provide a minimal viable seed path (empty db + schema init)
# OR get an explicit contract exception. Do not silently omit db/.
#
# The postgres entrypoint runs anything in this directory on first start only —
# specifically, only when PGDATA is empty. A host that persists PGDATA in a
# named volume therefore will NOT restore a newer dump on upgrade. See the
# database-volume note in common/docs/HOST-CONTRACT.md.

# Runs BEFORE the dump (filename order) and hard-fails on a role mismatch.
# The dump carries OWNER TO statements, so POSTGRES_USER is a hard requirement
# rather than a naming convention — and it is the sort of value that looks
# safe to change.
COPY db/00-assert-role.sh /docker-entrypoint-initdb.d/00-assert-role.sh

# NOTE: demo.sql.gz is NOT committed. For tip work, this COPY will fail on a
# clean clone. That is intentional: see the note above. If a golden dump
# exists, CI injects it; if not, document the gap honestly in README.md.
# Uncomment when demo.sql.gz is available:
# COPY db/demo.sql.gz /docker-entrypoint-initdb.d/demo.sql.gz
