# Nautobot demo host

Run the Nautobot frisian-mcp demo from this directory. This host ships two
matched images: the Nautobot app image and the pre-seeded PostgreSQL image.

## Safety: localhost only

This demo ships known, published credentials by design. They make the demo
work with no setup step, but they also mean the stack is not safe to expose.

The default compose file binds the HTTP port to `127.0.0.1`. Leave it there
unless you are on a network you control. Binding to `0.0.0.0` publishes a demo
with public credentials.

The MCP surface is locked. In the measured build, unauthenticated POST/GET
requests to `/mcp/` returned `401`; an admin token saw `47` tools and a
read-tier token saw `26`.

## Quickstart

From the repository root:

```bash
cd nautobot
docker compose up
```

No flags, no copied `.env`, no repo-root setup step. The committed `.env`
contains published demo defaults and is part of the quickstart contract.

When the app is healthy, the local HTTP endpoint is:

```text
http://127.0.0.1:8080
```

Use the client snippets one directory up to connect:

```bash
TOKEN="D6_NAUTOBOT_READ_ONLY_TOKEN" \
ROUTE="mcp/read-only" \
../common/mcp-clients/curl-tools-list.sh
```

Replace the `D6_*` token placeholder with the final published demo token once
the credential-reset pass lands.

## First boot

The database image restores its baked `demo.sql.gz` the first time the
database starts. During that restore, the `db` service is intentionally not
healthy and the app waits behind the compose healthcheck.

Observed restore time: **pending D2/D4 measurement**.

Do not replace that line with an estimate. The final number comes from the
scratch restore/migration path and is written here so a first-time user knows
whether the wait is normal.

The starting change log is empty by design. Inherited object-change rows are
truncated before the public artifact is baked because they are a build-time
audit trail, not the demo estate. New changes made in the demo are logged
normally.

## Demo walkthrough

Use two identities against the same local stack:

1. Connect to `http://127.0.0.1:8080/mcp/read-only/` with the read-only demo
   token.
2. Call `tools/list`.
3. Reconnect to `http://127.0.0.1:8080/mcp/read-write/` with the scoped
   read-write demo token.
4. Call `tools/list` again.

The surfaces differ. The read-tier token sees the reduced manifest measured at
`26` tools; the full admin surface measured `47` tools. The scoped read-write
identity is finalized by D6 and should be documented here once minted.

Sensitive resources, including secrets and the inherited object-change trail,
are absent from the scoped routes. They do not merely fail at execution after
appearing in discovery.

## Image pinning

`DEMO_TAG` pins both images:

```text
ghcr.io/frisian-mcp/demo-nautobot:${DEMO_TAG}
ghcr.io/frisian-mcp/demo-nautobot-db:${DEMO_TAG}
```

The committed default is:

```text
DEMO_TAG=v0.1.0
```

There is no `latest` tag. The app image and database image are a matched pair;
running different tags is unsupported.

## Environment

You do not need to create `.env`. It is committed intentionally so a fresh
clone works with `docker compose up`.

Common values:

| Variable | Default | Meaning |
|---|---|---|
| `DEMO_TAG` | `v0.1.0` | Single tag for both demo images |
| `DEMO_BIND_HOST` | `127.0.0.1` | Host interface for published HTTP |
| `DEMO_HTTP_PORT` | `8080` | Host HTTP port |
| `POSTGRES_DB` | `nautobot` | Database name |
| `POSTGRES_USER` | `nautobot` | Database role required by the dump |
| `FRISIAN_MCP_HMAC_KEY` | fixed demo value | HMAC key for baked demo tokens |

`FRISIAN_MCP_HMAC_KEY` is public by design. Changing it breaks the baked demo
tokens because their stored digests were minted under that key.

For the full annotated reference, read [`.env.example`](.env.example).

## Local build

The normal path pulls images from GHCR. To build both images locally:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up --build
```

The local database image build requires `db/demo.sql.gz`. That file is not in
git; CI injects the credential-reset golden artifact. A local build without it
should fail rather than produce an empty database image.

## Stop and reset

Stop the stack:

```bash
docker compose down
```

Reset local demo state:

```bash
docker compose down -v
```

The reset deletes local volumes, including the restored demo database and the
per-deployment secret key generated on first boot.
