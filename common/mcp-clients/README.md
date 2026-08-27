# MCP client snippets

Ready-to-paste client configuration and raw JSON-RPC smoke tests for the local
demos.

## Which host

Two demo hosts ship in this repository, on different ports so both can run at
once. Everything from "The demo identities" down to "Paths" describes the
**Nautobot** host; the **Paperless** host has its own section at the bottom.

| host | start it with | base URL | client template |
|---|---|---|---|
| Nautobot | `cd nautobot && docker compose up` | `http://127.0.0.1:8080` | [`nautobot.mcp.json.template`](nautobot.mcp.json.template) |
| Paperless-ngx | `cd paperless && docker compose up` | `http://127.0.0.1:8081` | [`paperless.mcp.json.template`](paperless.mcp.json.template) |

The `curl-*.sh` scripts default to the Nautobot host. Set `BASE_URL` to reach
the other one:

```bash
BASE_URL="http://127.0.0.1:8081" TOKEN=... ROUTE=mcp/read-only ./curl-tools-list.sh
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

Static bearer tokens are the supported path for all three tiers, and are what
these snippets use.

A browser-based OAuth connect is also available, against a pre-registered
client that is published like everything else here. It lands at the `read`
tier — self-serve gets you read, while read-write and admin stay with the
provisioned tokens above. See the host README for the client ID, the registered
redirect URIs, and the approval step.

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

Both scoped doors return **12 tools with identical names** for `demo-readonly`
and `demo-netops` — but not because the group list belongs to the route.

Two filters run in series: the route's allow-list fixes the **candidate set**,
and permission-aware discovery then filters **within** it, per identity. On
these doors the allow-list has already removed nearly everything those two
identities differ on, so the second filter has little left to do. Ask the same
door as `demo-admin` and it returns **13** — the extra group is
`load_balancers`, which is on the allow-list and therefore mounted for
everyone, but hidden from `tools/list` for identities that cannot use it.

**So do not use `tools/list` lengths to demonstrate scoping on these doors** — a
reader who compares 12 against 12 concludes nothing is happening, and a reader
who compares 12 against 13 draws the wrong lesson from a single group. Use
`help` below, where the per-identity difference is plain.

The `/mcp/admin/` door carves nothing, so no candidate set is narrowed first and
the spread is obvious: 23, 38, and 47 tools for `demo-readonly`, `demo-netops`,
and `demo-admin`, all against the same URL.

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

Run these scripts from this directory, or from a host directory as
`../common/mcp-clients/curl-help.sh`.

---

# The Paperless-ngx host

```bash
cd paperless
docker compose up
```

```text
http://127.0.0.1:8081
```

Everything above about *mechanism* applies unchanged — the same route model,
the same tier ceilings, the same permission-aware discovery. What differs is
the estate, the groups and the identity in the middle.

## The demo identities

| identity | door | tier ceiling | bearer token |
|---|---|---|---|
| `demo-readonly` | `/mcp/read-only/` | `read` | `frisian-demo-readonly-token-public-do-not-reuse` |
| `demo-editor` | `/mcp/read-write/` | `read_write` | `frisian-demo-editor-token-public-do-not-reuse` |
| `demo-admin` | `/mcp/ops/` | `admin` | `frisian-demo-admin-token-public-do-not-reuse` |

`readonly` and `admin` are deliberately the same token strings as the Nautobot
host uses: an identity that means the same thing on both surfaces should not
need a different line in a client config. Only the scoped writer differs,
because the scoped writer is host-specific by nature.

`demo-editor` can write only `Document` and `Tag`, even though its door permits
the write tier across all five scoped groups. **A refusal there is the feature,
not a bug.**

## Available groups

`documents`, `classification`, `mail`, `workflow`, `monitoring` — and, on the
admin door only, `sharing` and `system`.

## The comparison worth running

Unlike the Nautobot host, `tools/list` lengths ARE meaningful here — and the
middle door is the smallest:

```bash
BASE_URL="http://127.0.0.1:8081" TOKEN="frisian-demo-readonly-token-public-do-not-reuse" \
  ROUTE=mcp/read-only ./curl-tools-list.sh      # 5

BASE_URL="http://127.0.0.1:8081" TOKEN="frisian-demo-editor-token-public-do-not-reuse" \
  ROUTE=mcp/read-write ./curl-tools-list.sh     # 4  <- fewer, not more

BASE_URL="http://127.0.0.1:8081" TOKEN="frisian-demo-admin-token-public-do-not-reuse" \
  ROUTE=mcp/ops ./curl-tools-list.sh            # 7
```

`system` and `sharing` are off both scoped allow-lists. `workflow` is denied on
the read-write door only: a WorkflowAction carries webhook URLs, bodies and
headers and the engine fires them on document events, so browsing the
automation catalogue is harmless and writing it is not. On the read door the
`read` tier ceiling already makes those writes impossible, so the catalogue can
stay.

It is a route-level deny, so it holds for the superuser too:

```bash
BASE_URL="http://127.0.0.1:8081" TOKEN="frisian-demo-admin-token-public-do-not-reuse" \
  ROUTE=mcp/read-write ./curl-tools-list.sh     # still 4
```

The sharper demonstration is still one level down, and it is a single
dispatcher split by one principal's permissions:

```bash
# demo-editor, read-write door, ONE group: `tag` has write actions,
# `correspondent` does not. Same door, same dispatcher, same request.
BASE_URL="http://127.0.0.1:8081" TOKEN="frisian-demo-editor-token-public-do-not-reuse" \
  ROUTE=mcp/read-write ./curl-help.sh classification
```

```bash
# The tier ceiling, independent of any permission: the admin token on the
# read-only door still gets no write action.
BASE_URL="http://127.0.0.1:8081" TOKEN="frisian-demo-admin-token-public-do-not-reuse" \
  ROUTE=mcp/read-only ./curl-help.sh classification
```
