# frisian-mcp demo — Teable

> ⚠️ **Phase 7 tip work** — this is the first Nest host in frisian-mcp-demo.
> Identity provisioning, MCP doors, and golden SQL dump are deferred. See the
> "Current Status" section below.

**[Teable](https://github.com/teableio/teable)** is a modern, collaborative
database platform — think Airtable, but self-hosted and open source. This demo
host shows how frisian-mcp integrates with **NestJS applications** using the
`@frisian-mcp/nestjs-test` and `@frisian-mcp/core-test` npm packages.

## What this demonstrates

- **Nest integration** — frisian-mcp as npm packages, not pip wheels
- **npm lanes** — local tarballs (rehearsal) vs registry `next` vs `release`
- **SDK peer dependency** — `@modelcontextprotocol/sdk` installed directly
  (measured miss from P6-2b)
- **Self-contained host** — `cd teable && docker compose up` works on a fresh
  clone, with no flags and no preparation

## Current status (Phase 7 tip)

✅ **Working:**
- Dockerfile installs Frisian nestjs-test + core-test + SDK peer
- Build-time assertions verify package versions and SDK resolution
- Zero-flag compose boots Teable + postgres + redis
- Acceptance script validates package installation and database health

🚧 **Deferred:**
- **No golden SQL dump yet** — db image documents the gap in `db/Dockerfile`;
  acceptance runs against an empty/initialized schema
- **Identity provisioning is a placeholder** — `db/provision_identities.py`
  and `db/assert-identities.sh` document the intended design but are not
  implemented
- **MCP doors are not wired** — Teable's base image has no frisian-mcp routes;
  acceptance checks are placeholders for when Nest MCP integration is deployed
- **No GHCR publish** — workflow builds and verifies only; publish job is
  commented out until the above are ready

## Quickstart (60 seconds)

Pull the prebuilt images and boot the stack:

```bash
cd teable
docker compose up -d --wait
```

First boot takes ~2 minutes while the database initializes.

Teable UI: [http://127.0.0.1:3000](http://127.0.0.1:3000)

When ready, tear down:

```bash
docker compose down -v
```

The `-v` is important: it wipes the demo estate. Without it, edits to the
database survive `down` and `restart`, which is not the demo's design.

## MCP client configuration (placeholder)

The three client configs are present (`.mcp.json`, `.cursor/mcp.json`,
`.codex/config.toml`) and declare three doors:

| Door | URL | Tier | Published Bearer token |
|---|---|---|---|
| `teable-read-only` | `http://127.0.0.1:3000/api/mcp/read-only` | read | `frisian-demo-readonly-token-public-do-not-reuse` |
| `teable-read-write` | `http://127.0.0.1:3000/api/mcp/read-write` | read_write | `frisian-demo-user-token-public-do-not-reuse` |
| `teable-ops` | `http://127.0.0.1:3000/api/mcp/ops` | admin | `frisian-demo-admin-token-public-do-not-reuse` |

**These routes do not exist yet** in the base Teable image. The configs
document the intended structure for when frisian-mcp Nest integration is
deployed.

From the `teable/` directory:

```bash
# Claude Code
claude

# Cursor
cursor

# Codex
CODEX_HOME="$PWD/.codex" codex
```

## Safety banner

**⚠️ DO NOT expose this demo to the internet.**

This stack ships **published credentials by design**. The tokens, passwords and
HMAC key are in this README, in `.env`, and baked into the images. Binding to
`0.0.0.0` is an explicit act by you, never a default — and it publishes a
working Teable instance with known credentials.

The compose file binds to `127.0.0.1` by default. Leave it that way.

## Building locally

### Prerequisites

- Docker + Buildx
- For local tarball lane: `@frisian-mcp/nestjs-test` and
  `@frisian-mcp/core-test` npm packages packed as `.tgz` and placed in
  `teable/.frisian/`

### npm-next lane (registry)

Installs from npm `next` dist-tag (tip bar Phase 7: nestjs-test@0.0.4-rc.3,
core-test@0.1.0-rc.14):

```bash
cd teable
FRISIAN_NPM_NEXT=1 docker compose -f docker-compose.yml -f docker-compose.build.yml build
docker compose up -d --wait
```

### Local tarball lane (rehearsal)

For testing unreleased Frisian packages:

```bash
# Pack tarballs from frisian-mcp monorepo (or wherever built)
npm pack @frisian-mcp/nestjs-test
npm pack @frisian-mcp/core-test
cp *.tgz /path/to/frisian-mcp-demo/teable/.frisian/

# Build
cd teable
FRISIAN_LOCAL_TARBALLS=1 docker compose -f docker-compose.yml -f docker-compose.build.yml build
docker compose up -d --wait
```

Tarballs are gitignored by design (build inputs, not repo artifacts). See
`.frisian/README.md` for details.

## Acceptance

From the repo root:

```bash
cd teable && docker compose up -d --wait
./common/ci/acceptance-teable.sh
```

The script validates:
- Stack boots and is healthy
- Frisian npm packages installed (nestjs-test, core-test)
- `@modelcontextprotocol/sdk` peer dependency resolves (P6-2b measured miss)
- Database schema initialized

MCP door checks and identity assertions are placeholders for Phase 7.

## What's in the estate (deferred)

**No golden SQL dump for Phase 7 tip work.** When seeding is implemented, this
section will document:
- Demo identities (demo-readonly, demo-user, demo-admin)
- Sample Teable workspaces, tables, and records
- API tokens and OAuth client

For now, the database boots empty with only Teable's core schema initialized.

## Publishing (Jeremy only)

**NOT enabled for Phase 7 tip work.** The workflow builds and verifies but does
not publish. Uncomment the publish job in `.github/workflows/build-teable.yml`
when:

1. Golden SQL dump exists and is injected by CI
2. Identity provisioning is implemented and verified
3. MCP doors are wired and acceptance passes full door checks
4. Jeremy approves GHCR publish for this host

Rehearsal publish via `publish.sh`:

```bash
cd teable
./publish.sh            # dry run
./publish.sh --push     # publish to GHCR (Jeremy only)
```

See `common/docs/PUBLISHING.md` npm lanes section.

## Environment variables

See `.env.example` for the full annotated list. Key settings:

| Variable | Default | Purpose |
|---|---|---|
| `DEMO_TAG` | `v0.1.0-rc.1` | Both images, lockstep. Never split. |
| `DEMO_BIND_HOST` | `127.0.0.1` | Host interface. **Never default to 0.0.0.0** |
| `DEMO_HTTP_PORT` | `3000` | Teable HTTP port |
| `POSTGRES_USER` | `teable` | Database role. **DO NOT CHANGE** without updating `db/00-assert-role.sh` |
| `SECRET_KEY` | demo constant | App secret. Changing this breaks tokens. |

## Files

Per `common/docs/HOST-CONTRACT.md` required files table (Nest deltas noted):

| Path | Purpose | Notes |
|---|---|---|
| `Dockerfile` | App image: upstream Teable + Frisian npm packages | Nest lane logic (tarballs OR npm-next) |
| `docker-compose.yml` | Default path, pulls prebuilt images | Zero-flag, loopback bind, tmpfs PGDATA |
| `docker-compose.build.yml` | Build override | Build args only |
| `.env` | Published demo values (committed) | |
| `.env.example` | Annotated reference | |
| `db/Dockerfile` | Pre-seeded database image | SQL text, not PGDATA; documents missing dump |
| `db/00-assert-role.sh` | Role assertion before restore | |
| `db/provision_identities.py` | Identity provisioner (placeholder) | Nest tokens TBD |
| `db/assert-identities.sh` | Independent identity assertion (placeholder) | |
| `.mcp.json`, `.cursor/mcp.json`, `.codex/config.toml` | Client configs | Three doors (routes TBD) |
| `.frisian/` | Local npm tarballs (gitignored) | Nest rehearsal lane |
| `publish.sh` | Build + publish script | Dry-run by default |
| `README.md`, `GETTING-STARTED.md` | Documentation | |

## Troubleshooting

### Build fails: "no .tgz found in .frisian/"

You set `FRISIAN_LOCAL_TARBALLS=1` but no tarballs are present. Either pack
them (see `.frisian/README.md`) or use the npm-next lane instead:

```bash
FRISIAN_NPM_NEXT=1 docker compose -f docker-compose.yml -f docker-compose.build.yml build
```

### Build fails: "@modelcontextprotocol/sdk/server/index.js does not resolve"

The SDK peer dependency is missing. This is the P6-2b measured miss. The
Dockerfile should catch this at build time. If it doesn't, file a bug.

### Database is not seeding

**Expected for Phase 7 tip work** — there is no golden SQL dump yet.
`db/Dockerfile` documents this gap. The database boots with Teable's core
schema only.

### MCP doors return 404

**Expected for Phase 7 tip work** — the base Teable image has no frisian-mcp
routes. MCP integration is deferred.

## See also

- `common/docs/HOST-CONTRACT.md` — per-host contract and checklist
- `common/docs/PUBLISHING.md` — npm lanes and publish runbook
- `GETTING-STARTED.md` — ordered walkthrough (when MCP doors are live)
- [Teable upstream](https://github.com/teableio/teable)
- [Teable docs](https://help.teable.ai/)

---

**This is a demo.** The credentials are public. Do not reuse them. Do not
expose this stack to the internet.
