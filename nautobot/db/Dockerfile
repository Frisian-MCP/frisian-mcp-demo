# Pre-seeded PostgreSQL for the Nautobot demo host.
#
# Deliberately trivial, and it must stay that way.
#
# This image bakes SQL TEXT, never a pre-initialised PGDATA. A data directory
# is architecture-sensitive, which would drag Postgres startup, migrations and
# provisioning through QEMU on the arm64 leg of the multi-arch build. SQL text
# is architecture-independent, so the seed runs once natively on amd64 and both
# architectures reuse it — which reduces this image's build to a file copy.
#
# That is why the C-track is cheap. Do not "optimise" it into a baked data
# directory.
#
# Build context is the HOST directory (nautobot/), not db/:
#   docker build -f db/Dockerfile nautobot/

# Pinned major, measured rather than assumed. Nautobot 3.2.3 sets a 14.0 floor
# and states no ceiling, but the application image ships libpq 17 — that is the
# real ceiling. 17 sits at the top of the supported window and is
# version-matched to the client in the app image.
#
# ⚠️ PIN THE MAJOR ONLY. The effective requirement is postgres >= 17.6.
#
# Pinning a specific minor looks more careful and is the likely "improvement"
# someone makes here. It is not safe below 17.6, and 17.4 — which is what
# Homebrew ships today, so it is the number nearest to hand — breaks every
# restore. `postgres:17` tracks the latest 17.x and satisfies the floor; a
# narrower pin has to be checked against it deliberately, not guessed.
ARG POSTGRES_MAJOR=17
FROM postgres:${POSTGRES_MAJOR}

ARG POSTGRES_MAJOR
ARG DEMO_TAG=dev

LABEL org.opencontainers.image.source="https://github.com/Frisian-MCP/frisian-mcp-demo"
LABEL org.opencontainers.image.title="frisian-mcp demo — Nautobot database"
LABEL org.opencontainers.image.description="Pre-seeded PostgreSQL carrying the Nautobot demo estate. Ships published demo credentials by design."
LABEL org.opencontainers.image.version="${DEMO_TAG}"
LABEL org.frisian.demo.host="nautobot"
LABEL org.frisian.demo.postgres-major="${POSTGRES_MAJOR}"

# The golden dump. NOT in git — CI injects it here before building (see the
# seed job in .github/workflows/build-nautobot.yml), and .gitignore excludes
# it. If this COPY fails, the artifact is missing: build the image through the
# workflow, or place a locally produced demo.sql.gz at nautobot/db/ first.
#
# It must be the POST-credential-reset artifact from D6/D7. The pre-reset dump
# carries credentials that are live against an internet-facing host, and this
# image is published publicly.
#
# The postgres entrypoint runs anything in this directory on first start only —
# specifically, only when PGDATA is empty. A host that persists PGDATA in a
# named volume therefore will NOT restore a newer dump on upgrade. See the
# database-volume note in common/docs/HOST-CONTRACT.md.
# Runs BEFORE the dump (filename order) and hard-fails on a role mismatch.
# The dump carries 272 `ALTER TABLE ... OWNER TO nautobot;` statements, so
# POSTGRES_USER is a hard requirement rather than a naming convention — and it
# is the sort of value that looks safe to change.
COPY db/00-assert-role.sh /docker-entrypoint-initdb.d/00-assert-role.sh

COPY db/demo.sql.gz /docker-entrypoint-initdb.d/demo.sql.gz
