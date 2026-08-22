# frisian-mcp-demo

Clone-and-run frisian-mcp demos against real host applications. Nautobot is
the first host.

## Safety: localhost demo only

These images ship a pre-seeded database and known, published demo credentials
so the demo works out of the box. Treat every password, token, OAuth client,
API key, and seeded identity in the demo as public.

Do not expose this stack to the internet or to a shared network. If you keep a
copy for anything beyond a local throwaway demo, rotate every credential first.

The compose files bind published ports to `127.0.0.1` by default. That is a
control, not a convenience setting: binding to `0.0.0.0` publishes a stack with
published credentials. Change `DEMO_BIND_HOST` only on a network you control.

The shipped posture is locked. In the Nautobot build, unauthenticated requests
to the MCP endpoint returned `401`; an admin token saw `47` tools, while a
read-tier token saw `26`. Lower-privilege tools are absent from discovery, not
only refused after the agent tries them.

## 60-second quickstart

```bash
git clone https://github.com/Frisian-MCP/frisian-mcp-demo.git
cd frisian-mcp-demo/nautobot
docker compose up
```

When the app is healthy, connect an MCP client to the demo endpoint with one
of the published demo identities. Client templates and curl smoke tests live
under [`common/mcp-clients/`](common/mcp-clients/).

The default image tag is `v0.1.0`, set once in
[`nautobot/.env`](nautobot/.env). Both images use that same tag:

```text
ghcr.io/frisian-mcp/demo-nautobot:v0.1.0
ghcr.io/frisian-mcp/demo-nautobot-db:v0.1.0
```

There is no `latest` tag. The app image and database image are a matched pair;
do not run them at different tags.

## What you are looking at

frisian-mcp exposes host application operations as MCP tools, then shapes
`tools/list` to the identity that connected. That makes the demo useful to try
with more than one identity:

1. Connect with the read-only demo identity.
2. Call `tools/list`.
3. Reconnect with the scoped read-write demo identity.
4. Call `tools/list` again.

The surfaces differ. That contrast is the point of the demo: an agent sees the
tools it is allowed to plan with, and sensitive routes do not appear in the
lower-privilege manifest.

The starting change log is intentionally empty. The inherited object-change
history is truncated before the public database image is baked because it is a
build-time audit trail, not part of the demo estate. New changes made while
using the demo are still logged normally.

## Demo hosts

| Host | Path | Status |
|---|---|---|
| Nautobot | [`nautobot/`](nautobot/) | First demo host |

Each host directory is self-contained. The default path is always:

```bash
cd <host>
docker compose up
```

See [`common/docs/HOST-CONTRACT.md`](common/docs/HOST-CONTRACT.md) for the
per-host contract.

## MCP client snippets

The common snippets are intentionally separate from the host directory because
they are cross-host client material:

- [`common/mcp-clients/README.md`](common/mcp-clients/README.md) explains the
  expected identity shape.
- [`common/mcp-clients/nautobot.mcp.json.template`](common/mcp-clients/nautobot.mcp.json.template)
  contains ready-to-copy `mcpServers` blocks with D6 placeholders for the final
  demo tokens.
- [`common/mcp-clients/curl-tools-list.sh`](common/mcp-clients/curl-tools-list.sh)
  is the raw JSON-RPC smoke test for `tools/list`.

The final token names and values are produced by the credential-reset pass.
Until that lands, placeholders named `D6_*` are deliberate.

## Local build path

The default quickstart pulls prebuilt images from GHCR. To build both images
locally instead:

```bash
cd nautobot
docker compose -f docker-compose.yml -f docker-compose.build.yml up --build
```

The database image needs `nautobot/db/demo.sql.gz`, which is not committed.
CI injects the golden artifact after inherited credentials are reset. A local
database-image build without that file should fail rather than produce an
empty or unsafe demo.

## Publishing notes

Publishing is Jeremy-operated. Agents prepare files and local commits; they do
not push or publish.

For GHCR visibility, tag, retention, rollback, and clean-pull verification
rules, see [`common/docs/PUBLISHING.md`](common/docs/PUBLISHING.md).

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
