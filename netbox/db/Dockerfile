# Pre-seeded PostgreSQL for the NetBox demo host.
#
# Deliberately trivial, and it must stay that way.
#
# This image bakes SQL TEXT, never a pre-initialised PGDATA. A data directory
# is architecture-sensitive, which would drag Postgres startup, migrations and
# estate building through QEMU on the arm64 leg of the multi-arch build. SQL
# text is architecture-independent, so the seed runs once natively on amd64 and
# both architectures reuse it — which reduces this image's build to a file copy.
#
# Do not "optimise" it into a baked data directory.
#
# Build context is the HOST directory (netbox/), not db/:
#   docker build -f db/Dockerfile netbox/

# ⚠️ PIN THE MAJOR ONLY.
#
# The binding constraint is that the server major must be >= the pg_dump that
# produced demo.sql.gz. A newer pg_dump emits GUCs an older server rejects in
# the dump preamble, and the restore then fails — or, without ON_ERROR_STOP,
# half-succeeds.
#
# seed/seed.sh dumps from a container built on THIS image, so the two cannot
# drift as long as both read the same default. If you raise this, re-cut the
# dump; do not raise it and assume the old artifact still restores.
#
# NetBox 4.6 requires PostgreSQL 14 or later. 17 sits comfortably inside that
# window and matches the other demo hosts.
ARG POSTGRES_MAJOR=17
FROM postgres:${POSTGRES_MAJOR}

ARG POSTGRES_MAJOR
ARG DEMO_TAG=dev

LABEL org.opencontainers.image.source="https://github.com/Frisian-MCP/frisian-mcp-demo"
LABEL org.opencontainers.image.title="frisian-mcp demo — NetBox database"
LABEL org.opencontainers.image.description="Pre-seeded PostgreSQL carrying the NetBox demo estate. Ships published demo credentials by design."
LABEL org.opencontainers.image.version="${DEMO_TAG}"
LABEL org.frisian.demo.host="netbox"
LABEL org.frisian.demo.postgres-major="${POSTGRES_MAJOR}"

# Runs BEFORE the dump (filename order) and hard-fails on a role mismatch.
# POSTGRES_USER looks like a naming convention, which is exactly why it needs
# an assertion.
COPY db/00-assert-role.sh /docker-entrypoint-initdb.d/00-assert-role.sh

# The golden dump. NOT in git — .gitignore excludes it, because it is a build
# artifact. seed/seed.sh produces it; CI runs that seed and injects the result
# here before building.
#
# If this COPY fails, the artifact is missing. Build through the workflow, or
# run seed/seed.sh locally first.
#
# The postgres entrypoint runs this directory on first start only — that is,
# only when PGDATA is empty. A host that persists PGDATA in a named volume will
# NOT restore a newer dump on upgrade, which is why this host's compose file
# mounts PGDATA as a tmpfs. See common/docs/HOST-CONTRACT.md.
COPY db/demo.sql.gz /docker-entrypoint-initdb.d/demo.sql.gz
