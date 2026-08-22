# MCP client snippets

These snippets connect an MCP client to the local Nautobot demo started by:

```bash
cd nautobot
docker compose up
```

Default local base URL:

```text
http://127.0.0.1:8080
```

## Identity placeholders

The final demo identities are minted during the credential-reset pass. Until
that lands, placeholders named `D6_*` are intentional and must not be replaced
with invented values.

Expected shape:

| Placeholder | Route | Purpose |
|---|---|---|
| `D6_NAUTOBOT_READ_ONLY_TOKEN` | `/mcp/read-only/` | Read-tier view of the demo estate |
| `D6_NAUTOBOT_READ_WRITE_TOKEN` | `/mcp/read-write/` | Scoped read-write view of the same estate |
| `D6_NAUTOBOT_ADMIN_TOKEN` | `/mcp/admin/` | Full demo surface, mainly for validation |

Measured during the Nautobot build: unauthenticated requests returned `401`;
an admin token saw `47` tools and a read-tier token saw `26`.

## mcpServers template

Copy [`nautobot.mcp.json.template`](nautobot.mcp.json.template), replace the
`D6_*` token placeholders with the published demo tokens, and merge the
`mcpServers` block into your MCP client config.

Use one server at a time when demonstrating permission-aware discovery. Connect
as read-only, call `tools/list`, then reconnect as read-write and call
`tools/list` again. The read-write identity should see a larger surface.

## Curl smoke tests

Unauthenticated requests should be refused:

```bash
curl -i \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  http://127.0.0.1:8080/mcp/read-only/
```

Authenticated `tools/list`:

```bash
TOKEN="D6_NAUTOBOT_READ_ONLY_TOKEN" \
ROUTE="mcp/read-only" \
./common/mcp-clients/curl-tools-list.sh
```

From inside `nautobot/`, call the script with `../common/mcp-clients/...`.
