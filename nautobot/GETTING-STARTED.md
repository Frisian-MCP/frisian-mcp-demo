# Getting started

Stock Nautobot with one settings file swapped in. Everything below is what that
file configures.

Everything here — passwords, tokens, keys — is **published on purpose**. They are
fixed constants, identical in every build, and they are not secrets. The safety
property is that the stack binds to `127.0.0.1`. Do not reuse any of them, and do
not bind this stack to `0.0.0.0`.

## 1. Bring it up

```bash
cd nautobot
docker compose up
```

First boot pulls two images; after that it is seconds. The estate is restored on
**every** start, so nothing you do here is permanent.

## 2. Log in to the web UI

<http://127.0.0.1:8080>

| username | password |
|---|---|
| `demo-admin` | `frisian-demo-public-password` |
| `demo-netops` | `frisian-demo-public-password` |
| `demo-readonly` | `frisian-demo-public-password` |

All three share the same password. **Paste it** — if your browser autofills a
saved Nautobot password the login fails, and Django blanks the field, so there is
nothing on screen showing what was sent.

## 3. Connect your agent

The config files are already in this folder, pointing at all three doors. Nothing
to fill in.

| client | file | how it is picked up |
|---|---|---|
| Claude Code | `.mcp.json` | run `claude` from this folder |
| Cursor | `.cursor/mcp.json` | open this folder as the workspace |
| Codex | `.codex/config.toml` | `CODEX_HOME="$PWD/.codex" codex` — Codex reads `~/.codex/config.toml` by default, so it needs pointing here |

Each file declares three servers, one per door:

```
nautobot-read-only    http://127.0.0.1:8080/mcp/read-only
nautobot-read-write   http://127.0.0.1:8080/mcp/read-write
nautobot-admin        http://127.0.0.1:8080/mcp/admin
```

For a GUI client that takes JSON in its own settings rather than a repo file —
Claude Desktop and most others — paste this:

```json
{
  "mcpServers": {
    "nautobot-read-only": {
      "type": "http",
      "url": "http://127.0.0.1:8080/mcp/read-only",
      "headers": {
        "Authorization": "Bearer frisian-demo-readonly-token-public-do-not-reuse"
      }
    },
    "nautobot-read-write": {
      "type": "http",
      "url": "http://127.0.0.1:8080/mcp/read-write",
      "headers": {
        "Authorization": "Bearer frisian-demo-netops-token-public-do-not-reuse"
      }
    },
    "nautobot-admin": {
      "type": "http",
      "url": "http://127.0.0.1:8080/mcp/admin",
      "headers": {
        "Authorization": "Bearer frisian-demo-admin-token-public-do-not-reuse"
      }
    }
  }
}
```

The scheme is `Bearer`. A Nautobot API token would normally be `Token`, and that
returns `401` on every door here.

## The three identities

Each account has a **door**, a **tier ceiling**, and its **own Django
permissions**. Those are independent controls, and telling them apart is the
point of the demo.

| account | password | door | tier ceiling | Django permissions |
|---|---|---|---|---|
| `demo-readonly` | `frisian-demo-public-password` | `/mcp/read-only` | `read` | `view` on the scoped estate |
| `demo-netops` | `frisian-demo-public-password` | `/mcp/read-write` | `read_write` | `view` on all scoped apps; **write on `dcim` and `ipam` only** |
| `demo-admin` | `frisian-demo-public-password` | `/mcp/admin` | `admin` | superuser — bypasses per-object permissions |

| | read the estate | write `dcim`/`ipam` | write `dns`, `circuits`, `bgp`… | `users`, `vpn`, secrets |
|---|---|---|---|---|
| `demo-readonly` | yes | no | no | no |
| `demo-netops` | yes | yes | **refused** | no |
| `demo-admin` | yes | yes | yes | yes |

**`demo-netops` is the interesting one.** Its door permits the write tier across
all twelve scoped groups; its own permissions permit writes to two. So it gets
refused a write its door plainly allows — and that refusal is the feature. If
both controls were set the same, you could not tell which one was doing the work.

Each token is only accepted at its own door, and `/mcp/` itself is `404`, so the
doors never collapse onto a default mount.

## Two things worth trying first

**Do not compare `tools/list` lengths on the scoped doors.** It is the intuitive
move and it proves nothing — both return 12 tools with identical names. Two
filters run in series: the route's allow-list fixes the candidate set, then
permission-aware discovery filters within it. On the scoped doors the first
filter has already removed almost everything the two identities differ on.

The same door, asked by `demo-admin`, returns **13**:

```
/mcp/read-only    demo-readonly   12
/mcp/read-write   demo-netops     12
/mcp/read-only    demo-admin      13    <- load_balancers
```

`load_balancers` is on that door's allow-list, so it is mounted for everyone —
*hidden* from identities that cannot use it, not absent. Invoking it proves the
difference, because a refusal is not the same answer as a missing route:

```
demo-readonly   403  "You do not have permission to use 'loadbalancerpool'/'list'"
demo-admin      200
```

**Ask a dispatcher what it will let you do.** Send `action: "help"` to `dcim` and
then to `dns` as `demo-netops`. Same door, same token, two different answers —
that is where the per-identity difference shows plainly.

## Resetting

The database runs on a `tmpfs`, so the estate is restored on **every** start,
including `docker compose restart`. Break anything; a restart puts it back.

```bash
docker compose restart                    # reset the estate, keep the stack
docker compose down -v --remove-orphans   # stop and discard everything
```

## The file this is all about

`config/nautobot_config.py`, mounted over Nautobot's own settings file. Read it,
change it, `docker compose restart`.
