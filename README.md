# frisian-mcp-demo

Clone-and-run demos of [frisian-mcp](https://github.com/Frisian-MCP/frisian-mcp)
against real host applications. Each demo ships a pre-built estate and
pre-provisioned agent identities, so you can reach a real tool call in about a
minute. Nautobot was the first host; Paperless-ngx is the second.

## Safety: localhost demo only

**These images ship known, published credentials by design.** Every token,
password, and key used by these demos is printed in this repository and baked
into the published images. That is what removes the setup step, and it is also
why the stack is not safe to expose.

Do not put this on the internet or a shared network. If you keep a copy for
anything beyond a local throwaway demo, rotate every credential first.

The compose files bind published ports to `127.0.0.1`, and the applications
answer only to localhost hostnames. Both are controls rather than defaults to
tidy up — widening either publishes a stack whose administrative credentials
are in a public git repository. Change them only on a network you control.

The shipped posture is **locked**: authentication is required on every door,
and unauthenticated requests are refused rather than served a reduced view.
There is no unauthenticated walk-up mode in these images.

## 60-second quickstart

```bash
git clone https://github.com/Frisian-MCP/frisian-mcp-demo.git
cd frisian-mcp-demo/nautobot
docker compose up
```

The stack is ready in about a minute once the images are downloaded. The demo
estate is restored on **every** start, including `docker compose restart`, so
changes you make while exploring do not survive one — and getting back to a
clean estate never takes more than a restart.

When the stack is healthy, point an MCP client at it using one of the published
demo identities from
[`common/mcp-clients/`](common/mcp-clients/), or check it from a shell:

```bash
TOKEN="frisian-demo-readonly-token-public-do-not-reuse" \
ROUTE="mcp/read-only" \
./common/mcp-clients/curl-tools-list.sh
```

## What you are looking at

frisian-mcp exposes a host application's operations as MCP tools, and then
shapes what each connected agent can *see* according to who that agent is.
Tools an identity may not use are **absent from discovery**, not offered and
then refused — so an agent never plans a call it cannot make.

The demo makes that visible by shipping three identities with genuinely
different authority, against one server:

| identity | door | tier ceiling | may write |
|---|---|---|---|
| `demo-readonly` | `mcp/read-only` | `read` | nothing |
| `demo-netops` | `mcp/read-write` | `read_write` | `dcim` and `ipam` only |
| `demo-admin` | `mcp/ops` | `admin` | everything |

Ask one dispatcher what it will let you do, as `demo-netops`, on the door that
permits the write tier across every group:

```bash
cd nautobot
TOKEN="frisian-demo-netops-token-public-do-not-reuse" ROUTE="mcp/read-write" \
  ../common/mcp-clients/curl-help.sh dcim     # create, update, ... present

TOKEN="frisian-demo-netops-token-public-do-not-reuse" ROUTE="mcp/read-write" \
  ../common/mcp-clients/curl-help.sh dns      # list, retrieve, notes. no writes.
```

One identity, one token, one door, two different answers — because two
independent controls are at work. The route decides what the *door* exposes;
the identity's own permissions decide what the *principal* may touch. When they
disagree, the stricter one wins, and you can only see which is which by
watching an identity be refused something its door plainly allows.

**A refusal there is the feature.** The full walkthrough, including the case
where the more privileged door deliberately carries *less* surface, is in the
host README.

> One thing to skip: comparing `tools/list` lengths between the two scoped
> doors. Both return 12 identically-named tools for `demo-readonly` and
> `demo-netops` — not because the group list belongs to the route, but because
> the route's allow-list has already removed nearly everything those two differ
> on. `demo-admin` sees 13 on the same door. The per-identity difference is
> real everywhere; it is simply plainest one level down, in each dispatcher's
> action list, which is what `help` returns.

## Demo hosts

| Host | Path | Port | The estate |
|---|---|---|---|
| Nautobot | [`nautobot/`](nautobot/) | 8080 | a network: sites, devices, interfaces, circuits, addressing |
| Paperless-ngx | [`paperless/`](paperless/) | 8081 | a document archive: invoices, statements, contracts, reports |
| NetBox | [`netbox/`](netbox/) | 8083 | a network: two datacentres, spine-and-leaf, circuits, addressing |

Different ports, so all of them can run at once — which is the point of having
more than one. The mechanism is identical and the domain is not, so watching the
same route model carve a document archive and a network estate is what
separates "this works for network data" from "this works".

**NetBox is the one to start with if what you want to see is per-route
permissions.** The other two hosts give three identities a single mount point,
so the only variable is who you are. NetBox configures `FRISIAN_MCP_ROUTES` and
gives you three *doors* as well — which means you can send one credential at two
URLs and watch it be offered a different tool surface on each. That separation
between "the door caps this" and "your grant caps this" is hard to show with one
mount point and immediate with three.

Each host directory is self-contained, and the entry path is always the same:

```bash
cd <host>
docker compose up            # netbox: use `up -d`, see its README
```

Start with the host README —
[`nautobot/README.md`](nautobot/README.md),
[`paperless/README.md`](paperless/README.md) or
[`netbox/README.md`](netbox/README.md) — each carries the quickstart, the
identity roster, the first-boot expectations, and the full walkthrough. See
[`common/docs/HOST-CONTRACT.md`](common/docs/HOST-CONTRACT.md) for what any
host directory must provide.

### The identities are not interchangeable between hosts

The `read` and `admin` tokens are deliberately the same strings on every host,
because an identity that means the same thing on each surface should not need a
different line in a client config. The scoped writer in the middle is
host-specific by nature — `demo-netops` on Nautobot and NetBox, `demo-editor`
on Paperless — because what a narrow write grant should cover depends entirely
on what the estate is.

The URLs are not interchangeable either, and only on NetBox does that matter:
its three doors live at `/api/mcp/read-only`, `/api/mcp/read-write` and
`/api/mcp/ops`, where the other hosts use one mount point for all three
identities.

## Images

Each host publishes a matched pair of images — the application and its
pre-seeded database — pinned to one tag:

```text
ghcr.io/frisian-mcp/demo-nautobot:v0.1.0
ghcr.io/frisian-mcp/demo-nautobot-db:v0.1.0

ghcr.io/frisian-mcp/demo-paperless:v0.1.0
ghcr.io/frisian-mcp/demo-paperless-db:v0.1.0

ghcr.io/frisian-mcp/demo-netbox:v0.1.0
ghcr.io/frisian-mcp/demo-netbox-db:v0.1.0
```

**There is no `latest` tag**, and a pair must not be split. The database
carries identities whose tokens are verified by a key the application image
holds, so mismatched tags fail in ways that look like broken authentication.
The tag is set once per host, in that host's committed `.env`.

On the Paperless host there is a second reason: its estate is split across the
two images. The database image carries the SQL and the application image
carries the document files that SQL points at, so a split pair gives you an
archive where every listing works and every download 404s.

## MCP client snippets

[`common/mcp-clients/`](common/mcp-clients/) holds cross-host client material:
a ready-to-paste `mcpServers` block with working tokens, and raw JSON-RPC smoke
tests for `tools/list` and `help`.

## Local build

The quickstart pulls prebuilt images. A host's **application** image also
builds from a clean clone:

```bash
cd nautobot
docker compose -f docker-compose.yml -f docker-compose.build.yml build nautobot
```

The **database** image is host-specific, and the two hosts differ here for a
real reason.

**Nautobot's** is meant to be pulled. It bakes in a pre-seeded SQL artifact
that is deliberately not committed, produced outside this repository after the
estate's inherited credentials have been reset — that estate descends from a
live instance. Building it on a clean clone fails at the missing file, which is
the intended outcome: an empty database image that looks like a working demo
would be worse than a build error.

**Paperless's** builds from a clean clone, because its archive is generated
from fiction by scripts committed here and has no inherited credentials to
reset:

```bash
cd paperless
FRISIAN_MCP_LOCAL_WHEEL=<wheel> ./seed/seed.sh
docker compose -f docker-compose.yml -f docker-compose.build.yml up --build
```

Do not "align" the two. The asymmetry follows from where each estate came
from.

## Publishing

Publishing is operator-driven. For GHCR visibility, tagging, retention,
rollback, and clean-pull verification, see
[`common/docs/PUBLISHING.md`](common/docs/PUBLISHING.md).

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
