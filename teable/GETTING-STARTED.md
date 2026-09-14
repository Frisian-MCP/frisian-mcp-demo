# Getting Started with the Teable Demo

> ⚠️ **Phase 7 placeholder** — this guide documents the intended walkthrough
> once MCP doors and identity provisioning are implemented. For now, the stack
> boots but MCP integration is deferred.

This guide walks through the Teable demo host in the order you should try
things: GUI first, then the MCP agent.

## Prerequisites

- Docker + Compose
- An MCP client: [Claude Desktop](https://claude.ai/download),
  [Cursor](https://cursor.sh/), or [Codex](https://github.com/anysphere/codex)

## Step 1: Boot the stack

From the `teable/` directory:

```bash
docker compose up -d --wait
```

First boot takes ~2 minutes while the database initializes. Watch the logs if
you like:

```bash
docker compose logs -f teable
```

When healthy, the Teable UI is at [http://127.0.0.1:3000](http://127.0.0.1:3000).

## Step 2: Explore the Teable UI (placeholder)

**Deferred for Phase 7 tip work** — no golden SQL dump yet, so the estate is
empty. When seeding is implemented, this section will guide you through:

1. Logging in with demo credentials
2. Browsing sample workspaces and tables
3. Creating/editing records via the GUI
4. Understanding the three demo identities and their permissions

For now, the UI boots with Teable's default welcome screen.

## Step 3: Connect an MCP client (placeholder)

**Deferred for Phase 7 tip work** — MCP doors are not wired in the base Teable
image yet. When frisian-mcp Nest integration is deployed, follow these steps:

### Claude Desktop

The `.mcp.json` file in the `teable/` directory is ready for Claude Code to
discover. From the `teable/` directory:

```bash
claude
```

Claude lists three doors:
- `teable-read-only` — read tier, scoped view
- `teable-read-write` — read_write tier, scoped view + write on allowed resources
- `teable-ops` — admin tier, full access

### Cursor

Cursor reads `.cursor/mcp.json`. Open the `teable/` directory in Cursor, and
the three servers appear in the MCP panel.

### Codex

From the `teable/` directory:

```bash
CODEX_HOME="$PWD/.codex" codex
```

## Step 4: Try the read-only door (placeholder)

When MCP integration is live:

```
Connect to teable-read-only.

List the available tools. You should see Teable resources — workspaces, tables,
records — and actions scoped by the read tier ceiling.

Try:
  - List workspaces
  - Get a table schema
  - Query records from a table

What you should NOT see:
  - Create/update/delete actions (tier ceiling)
  - Resources outside the demo estate (scoping)
```

## Step 5: Try the read-write door (placeholder)

When MCP integration is live:

```
Connect to teable-read-write.

List the available tools. The read_write tier allows writes, but ONLY on
resources the demo-user identity is granted.

Try:
  - Create a new record in an allowed table
  - Update an existing record
  - Attempt to write to a restricted resource — it should refuse

This demonstrates the INDEPENDENT layers:
  - The door's tier ceiling (what actions are visible)
  - The identity's permissions (what the identity may actually do)
```

## Step 6: Try the ops door (placeholder)

When MCP integration is live:

```
Connect to teable-ops.

The admin tier + demo-admin superuser identity = full access. List tools and
confirm you see the complete surface, including actions the other doors denied.

Try:
  - Create/update/delete on any resource
  - Access admin-only operations (if Teable has them)
```

## Step 7: Compare the three doors (the demo's point)

**This is what the demo demonstrates**: one server, three doors, three
different `tools/list` responses. The same Teable backend, filtered by:

1. **Route tier ceiling** — what actions a door exposes at all
2. **Identity permissions** — what the connecting principal may actually do

When both are implemented, try:
- Query the same resource on all three doors — list size differs
- Attempt the same write on read-only (refused by tier) vs read-write (may
  succeed or fail depending on permissions)

## Tearing down

When finished:

```bash
docker compose down -v
```

The `-v` is important: it wipes the demo estate. Without it, your edits survive
`down` and `restart`, which is not the demo's design — the estate is meant to
reset on every start (see `common/docs/HOST-CONTRACT.md` tmpfs PGDATA section).

## What's next (Phase 7 roadmap)

1. **Implement identity provisioning** — `db/provision_identities.py` and
   `db/assert-identities.sh` move from placeholders to working scripts
2. **Wire MCP doors** — Deploy frisian-mcp Nest integration to Teable, define
   routes and scoping
3. **Produce golden SQL dump** — Seed the estate, provision identities, dump
   to `db/demo.sql.gz`
4. **Update this guide** — Replace placeholders with real walkthrough steps
5. **Enable GHCR publish** — Uncomment workflow publish job, merge to main

See `README.md` "Current Status" section for details.

## Troubleshooting

### Stack won't boot

Check logs:

```bash
docker compose logs
```

Common issues:
- Port 3000 already in use (`DEMO_HTTP_PORT` in `.env`)
- Database not healthy (wait longer, or check `docker compose ps`)

### MCP client doesn't list the servers

**Expected for Phase 7 tip** — doors are not wired yet. When they are, verify:
- You're in the `teable/` directory (clients read local config)
- Tokens in `.mcp.json` match `README.md` published constants
- Base URL is correct (`http://127.0.0.1:3000` by default)

### I can't log into the Teable UI

**Expected for Phase 7 tip** — no identities provisioned yet. When seeding is
implemented, credentials will be in `README.md`.

## See also

- `README.md` — safety, quickstart, building, publishing
- `common/docs/HOST-CONTRACT.md` — the per-host contract
- [Teable documentation](https://help.teable.ai/)

---

**This is a demo.** The credentials are public. Do not reuse them.
