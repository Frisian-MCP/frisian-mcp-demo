# MCP client snippets

Ready-to-paste client configuration and raw JSON-RPC smoke tests for the local
demo started by:

```bash
cd nautobot
docker compose up
```

Default local base URL:

```text
http://127.0.0.1:8080
```

## The demo identities

All three tokens are fixed, published constants. They are baked into the demo
images, printed here, and committed to this repository on purpose — they are
not secrets, and they are also not reusable for anything else.

| identity | door | tier ceiling | bearer token |
|---|---|---|---|
| `demo-readonly` | `/mcp/read-only/` | `read` | `frisian-demo-readonly-token-public-do-not-reuse` |
| `demo-netops` | `/mcp/read-write/` | `read_write` | `frisian-demo-netops-token-public-do-not-reuse` |
| `demo-admin` | `/mcp/admin/` | `admin` | `frisian-demo-admin-token-public-do-not-reuse` |

`demo-netops` can write only `dcim` and `ipam`, even though its door permits
the write tier across every scoped group. The door's ceiling and the
principal's own permissions are two independent controls, and watching that
identity be refused something its door plainly allows is how you tell them
apart. **A refusal here is the feature, not a bug.**

## Client configuration

Copy a block from [`nautobot.mcp.json.template`](nautobot.mcp.json.template)
into your MCP client configuration and merge it under `mcpServers`. The tokens
in it are real and work as printed — there is nothing to substitute.

Connect **one identity at a time** when demonstrating permission-aware
discovery, so the only thing that changes between two observations is the
identity.

Static bearer tokens are the supported path for this demo. The browser-based
OAuth connect flow is not available in this image; see the host README for why.

## Smoke tests

### Authentication is enforced

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  http://127.0.0.1:8080/mcp/read-only/
```

Expect `401`. There is no unauthenticated view of this demo.

### `tools/list` — the group surface

```bash
TOKEN="frisian-demo-readonly-token-public-do-not-reuse" \
ROUTE="mcp/read-only" \
./curl-tools-list.sh
```

Both scoped doors return **12 tools with identical names** for every identity.
That is correct: the scoped doors publish one dispatcher per resource group,
and the group list is a property of the route, not of the caller.

**So do not use `tools/list` lengths to demonstrate scoping on those doors** — a
reader who compares 12 against 12 will conclude nothing is happening. Use
`help` below.

The `/mcp/admin/` door applies no route carve, so counts there *do* vary by
identity: 23, 38, and 47 tools for `demo-readonly`, `demo-netops`, and
`demo-admin` respectively, all against the same URL.

### `help` — the action surface, and the real demonstration

```bash
TOKEN="frisian-demo-netops-token-public-do-not-reuse" \
ROUTE="mcp/read-write" \
./curl-help.sh dcim
```

`action: "help"` asks a dispatcher what it will let *this* caller do. The
per-identity difference lives here, one level below the tool list.

Two comparisons worth running, each changing exactly one variable:

```bash
# Same identity, same door, two groups -> writes on one, not the other
TOKEN="frisian-demo-netops-token-public-do-not-reuse" ROUTE="mcp/read-write" ./curl-help.sh dcim
TOKEN="frisian-demo-netops-token-public-do-not-reuse" ROUTE="mcp/read-write" ./curl-help.sh dns

# Same group, two identities -> read actions against read and write actions
TOKEN="frisian-demo-readonly-token-public-do-not-reuse" ROUTE="mcp/read-only"  ./curl-help.sh dcim
TOKEN="frisian-demo-netops-token-public-do-not-reuse"   ROUTE="mcp/read-write" ./curl-help.sh dcim
```

In every case the actions a caller may not take are **absent from the
response**, not present and refused on use. An agent planning against this
surface never proposes the call in the first place.

Available groups: `dcim`, `ipam`, `circuits`, `tenancy`, `virtualization`,
`wireless`, `cloud`, `golden_config`, `dns`, `bgp`, `ssot`, `extras`.

## Paths

Run these scripts from this directory, or from `nautobot/` as
`../common/mcp-clients/curl-help.sh`.
