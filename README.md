# frisian-mcp-demo

Clone-and-run demos of [frisian-mcp](https://github.com/Frisian-MCP/frisian-mcp)
against real host applications. Each demo ships a pre-built estate and
pre-provisioned agent identities, so you can reach a real tool call in about a
minute. Nautobot is the first host.

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
database is restored on every start, not just the first — that is deliberate,
and the host README explains why.

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
| `demo-admin` | `mcp/admin` | `admin` | everything |

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
> doors. Both return 12 identically-named tools for every caller, because the
> group list belongs to the route rather than the caller. The per-identity
> difference is one level down, in each dispatcher's action list, which is what
> `help` returns.

## Demo hosts

| Host | Path | Status |
|---|---|---|
| Nautobot | [`nautobot/`](nautobot/) | First demo host |

Each host directory is self-contained, and the entry path is always the same:

```bash
cd <host>
docker compose up
```

Start with [`nautobot/README.md`](nautobot/README.md) — it carries the
quickstart, the identity roster, the first-boot expectations, and the full
walkthrough. See
[`common/docs/HOST-CONTRACT.md`](common/docs/HOST-CONTRACT.md) for what any
host directory must provide.

## Images

Each host publishes a matched pair of images — the application and its
pre-seeded database — pinned to one tag:

```text
ghcr.io/frisian-mcp/demo-nautobot:v0.1.0
ghcr.io/frisian-mcp/demo-nautobot-db:v0.1.0
```

**There is no `latest` tag**, and the pair must not be split. The database
carries identities whose tokens are verified by a key the application image
holds, so mismatched tags fail in ways that look like broken authentication.
The tag is set once per host, in that host's committed `.env`.

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

The **database** image does not, and is meant to be pulled. It bakes in a
pre-seeded SQL artifact that is deliberately not committed — CI produces it
after the estate's inherited credentials have been reset. Building it on a
clean clone fails at that missing file, which is the intended outcome: an
empty database image that looks like a working demo would be worse than a
build error. See the host README for the detail.

## Publishing

Publishing is operator-driven. For GHCR visibility, tagging, retention,
rollback, and clean-pull verification, see
[`common/docs/PUBLISHING.md`](common/docs/PUBLISHING.md).

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
