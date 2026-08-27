# Getting started

You have `docker compose up` running and the stack is healthy. This is what to
actually do with it.

Everything below assumes the default `http://127.0.0.1:8081`.

## 1. Log in and look at the archive

**Do this first, before connecting any agent.**

```text
http://127.0.0.1:8081
```

| username | password |
|---|---|
| `demo-readonly` | `frisian-demo-public-password` |
| `demo-editor` | `frisian-demo-public-password` |
| `demo-admin` | `frisian-demo-public-password` |

One password, all three accounts. They are published demo constants, not
placeholders to substitute — see the safety banner in
[`README.md`](README.md) for why that is deliberate and why this stack stays
on loopback.

Start as `demo-admin` and have a look at what is in there:

- **24 documents**, six correspondents, two years of dates
- **8 tags** — `unpaid`, `tax-2026`, `medical`, `legal`, `warranty` …
- **3 custom fields** — account number, amount due, due date
- **2 saved views** on the dashboard — *Unpaid invoices*, *Tax year 2026*
- open any document: the original PDF, its thumbnail and a searchable text
  layer are all really there, so preview, download and full-text search work

This is the point of doing it first: **it is the ground truth you will compare
the agent against.** When an agent tells you there are four unpaid invoices,
you want to already know whether that is right.

It is also how you check an agent's writes. Have one retag a document, then
refresh the browser and watch it change.

> **All three accounts see the same 24 documents in the browser**, and that is
> correct rather than a bug. The web UI and the REST API answer to Paperless's
> own permission layer, where all three hold `view` on documents. What differs
> between the three identities is the **MCP tool surface** — which operations
> each one is even offered — and that is what the rest of this document is
> about. If you want to see the difference in the browser, try *editing* as
> `demo-readonly`.

## 2. Point your agent at all three doors

Copy the configuration for your client:

| client | file | how it is loaded |
|---|---|---|
| Claude Code | [`.mcp.json`](.mcp.json) | already here — run `claude` from this directory |
| Cursor | [`.cursor/mcp.json`](.cursor/mcp.json) | already here — open this directory as the workspace |
| Codex | [`.codex/config.toml`](.codex/config.toml) | `CODEX_HOME="$PWD/.codex" codex` |

All three declare **three** servers, not one:

```text
paperless-read-only    demo-readonly    read tier
paperless-read-write   demo-editor      read_write tier, narrowly scoped
paperless-ops          demo-admin       admin tier, superuser
```

Connect all three. The demo is the difference between them, and you cannot see
a difference from one connection.

> **Each connected door holds one server-side worker for as long as it stays
> connected.** The MCP streamable-HTTP transport opens a long-lived SSE stream
> per server. Three doors plus a browser is fine here; be aware of it if you
> add more clients.

## 3. Ask the read-only agent what it can see

> "What MCP tools do you have for the paperless read-only server?"

Five: `documents`, `classification`, `mail`, `workflow`, `monitoring`.

Not seven. `system` and `sharing` exist in this Paperless and are simply not on
this door — and **absent from a route is byte-identical to never-registered**,
so the agent has no way to tell a carved-out group from one that was never
installed. There is no forbidden response to probe against.

## 4. Ask it something real

> "Which invoices are unpaid, and who are they from? What is the total?"

Watch what the agent does: it calls `classification` to find the `unpaid` tag,
then `documents` to filter by it, then reads the `Amount due` custom field. It
did not need a tool schema for 117 actions to do that — it asked one dispatcher
for `help` and drilled in.

Follow up with something that exercises full-text search:

> "Find anything mentioning the boiler warranty and tell me when cover ends."

The corpus is born-digital PDFs with a real text layer, so the content is
genuinely indexed. This is not a metadata-only demo.

## 5. Now ask the same agent to change something

> "Rename the `urgent` tag to `needs-attention`."

Refused, and note *how*: on the read-only door the `update` action is not in
the dispatcher's action list at all. The route's `read` tier ceiling filtered
it out before any permission was consulted. Try it with the **admin** token
against the same read-only door and it is still absent — the ceiling narrows
regardless of who is asking, and it never grants.

## 6. Switch to the read-write door and try again

> "Using the paperless read-write server, rename the `urgent` tag to
> `needs-attention`."

That works. `demo-editor` holds `documents.change_tag`.

Now the interesting one:

> "Using the same server, rename the correspondent `Cascade Freight Co.` to
> `Cascade Logistics`."

Refused. Same door. Same identity. Same dispatcher — `correspondent` and `tag`
are both in `classification`. Nothing about the route distinguishes them.

What distinguishes them is that `demo-editor` holds `documents.change_tag` and
does not hold `documents.change_correspondent`, and frisian-mcp rebuilds each
dispatcher's action enum per request from `user.has_perm()`. The agent never
saw an `update` action for `correspondent` to attempt.

**That refusal is the whole point.** The door permits the write tier across
five groups; the principal permits two models; the stricter of the two wins.
If you find yourself widening the grant to make it succeed, you have turned
the demo off.

## 7. Compare the two write-capable doors

> "Compare the tools on the paperless read-write server with the ones on the
> paperless ops server. What is on one and not the other?"

The `workflow` group is on the read-only door and **not** on the read-write
one. That is not an oversight: a `WorkflowAction` carries webhook URLs, bodies
and headers, and the workflow engine fires them on document events, so creating
one is server-side request forgery with a form in front of it. Browsing them is
harmless; writing them is not.

More tier does not mean more surface.

## 8. Look at the token accounting

Every response carries a token count, and it is visible to the model as well as
to you (`FRISIAN_MCP_USAGE_REPORTING` and `FRISIAN_MCP_USAGE_IN_CONTENT` in
`config/paperless_frisian_mcp.py`). Ask a question that returns a lot:

> "List every document with its full metadata."

Watch the counter, and watch what happens when the response is too big to
return in one piece — the server hands back a continuation token rather than
truncating or blowing the context.

## 9. Break it and put it back

Everything in the archive is disposable:

```bash
docker compose restart
```

Both halves of the archive are restored on every start — the database from the
db image's initdb hook, the document files from a tarball baked into the
application image. Measured end to end on a warm machine: **22 seconds** from
`up` to a stack answering requests, of which the application's own init is
about seven.

## 10. Read the config

`config/paperless_frisian_mcp.py` is mounted from your clone, not baked in.
It is the entire demo: the three routes, the seven dispatch groups, the deny
lists, and a comment on every decision explaining what breaks if you change it.

Change something, `docker compose restart`, and reconnect your agent. The
surface changes.

Good first experiments:

- move `sharing` onto `_SCOPED_ALLOW` and watch a scoped door gain the ability
  to publish documents to the open internet
- take `mail:mailaccount` off `_SCOPED_DENY` and watch an IMAP password become
  a readable configuration object on the read-only door
- add `"documents:document"` to the read-write door's deny list and watch the
  agent lose the archive while keeping the tags

Each of those is a one-line edit and a restart, and each one is visible from
the agent side immediately. That is the fastest way to build an intuition for
what the route model actually controls.

## Where to go next

- [`README.md`](README.md) — the full walkthrough, the identity table, and what
  is deliberately absent from the archive
- [`../common/docs/HOST-CONTRACT.md`](../common/docs/HOST-CONTRACT.md) — what a
  demo host directory must provide, if you want to add one
- [`seed/`](seed/) — how the archive is built, from nothing, in one command
