# Pre-seeded PostgreSQL for the Paperless-ngx demo host.
#
# Deliberately trivial, and it must stay that way.
#
# This image bakes SQL TEXT, never a pre-initialised PGDATA. A data directory
# is architecture-sensitive, which would drag Postgres startup, migrations and
# document ingestion through QEMU on the arm64 leg of the multi-arch build. SQL
# text is architecture-independent, so the seed runs once natively on amd64 and
# both architectures reuse it — which reduces this image's build to a file copy.
#
# Do not "optimise" it into a baked data directory.
#
# Build context is the HOST directory (paperless/), not db/:
#   docker build -f db/Dockerfile paperless/

# ⚠️ PIN THE MAJOR ONLY.
#
# The constraint that actually binds is that the server major must be >= the
# pg_dump that produced demo.sql.gz. A newer pg_dump emits GUCs an older server
# rejects in the dump preamble, and the restore then fails — or, without
# ON_ERROR_STOP, half-succeeds.
#
# paperless/seed/seed.sh dumps from a container built on THIS image, so the two
# cannot drift as long as both read the same default. If you raise this, re-cut
# the dump; do not raise it and assume the old artifact still restores.
#
# 17 rather than 18 (which upstream's own compose file uses) because 17 is what
# the seed pipeline has been run against. Paperless supports both.
ARG POSTGRES_MAJOR=17
FROM postgres:${POSTGRES_MAJOR}

ARG POSTGRES_MAJOR
ARG DEMO_TAG=dev

LABEL org.opencontainers.image.source="https://github.com/Frisian-MCP/frisian-mcp-demo"
LABEL org.opencontainers.image.title="frisian-mcp demo — Paperless-ngx database"
LABEL org.opencontainers.image.description="Pre-seeded PostgreSQL carrying the Paperless-ngx demo estate. Ships published demo credentials by design."
LABEL org.opencontainers.image.version="${DEMO_TAG}"
LABEL org.frisian.demo.host="paperless"
LABEL org.frisian.demo.postgres-major="${POSTGRES_MAJOR}"

# Runs BEFORE the dump (filename order) and hard-fails on a role mismatch.
# POSTGRES_USER looks like a naming convention, which is exactly why it needs
# an assertion.
COPY db/00-assert-role.sh /docker-entrypoint-initdb.d/00-assert-role.sh

# The golden dump. NOT in git — .gitignore excludes it, because it is a build
# artifact and a large one. paperless/seed/seed.sh produces it; CI runs that
# seed and injects the result here before building.
#
# If this COPY fails, the artifact is missing. Build through the workflow, or
# run paperless/seed/seed.sh locally first.
#
# The postgres entrypoint runs anything in this directory on first start only —
# specifically, only when PGDATA is empty. A host that persists PGDATA in a
# named volume therefore will NOT restore a newer dump on upgrade. See the
# database-volume note in common/docs/HOST-CONTRACT.md, and note that this
# host's compose file mounts PGDATA as a tmpfs for exactly that reason.
COPY db/demo.sql.gz /docker-entrypoint-initdb.d/demo.sql.gz
