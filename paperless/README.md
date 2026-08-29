# Paperless-ngx demo host

A clone-and-run frisian-mcp demo against a real Paperless-ngx instance,
carrying a pre-built document archive and three pre-provisioned agent
identities.

This host ships two matched images: the Paperless-ngx application image and the
pre-seeded PostgreSQL image.

## Safety: localhost only

**This demo ships known, published credentials by design.** Every token,
password and HMAC key in this directory is printed in the open, committed to
this repository, and baked into the published images. They are what make the
demo work with no setup step, and they are the reason it is not safe to expose.

Treat this stack as public the moment it is reachable by anything but you.

The compose file binds the HTTP port to `127.0.0.1`. That is a control, not a
default anyone should tidy up: binding to `0.0.0.0` publishes an instance whose
administrative credentials are in a public git repository. Change
`DEMO_BIND_HOST` only on a network you control, and rotate everything first if
you intend to keep the instance.

`PAPERLESS_ALLOWED_HOSTS` is a second gate behind that one. It ships as
`localhost,127.0.0.1,[::1]`, so reaching the demo under any other hostname
fails at the Django layer even if the bind address is widened. Both have to be
changed deliberately; neither changes by accident.

### The posture is locked

Authentication is required on every door. Unauthenticated requests are refused,
not served a reduced view:

```console
$ curl -i -X POST http://127.0.0.1:8081/mcp/read-only/ -d '{}'
HTTP/1.1 401 Unauthorized
```

There is no unauthenticated walk-up mode in this image, and the setting that
enforces it is not one to experiment with — removing it does not loosen the
demo slightly, it republishes an open read door onto the whole archive.

## Quickstart

From the repository root:

```bash
cd paperless
docker compose up
```

No flags, no copied `.env`, no repository-root setup step. The committed `.env`
holds published demo defaults and is part of the quickstart contract.

When the stack is healthy the local endpoint is:

```text
http://127.0.0.1:8081
```

Port **8081**, not 8080 — the Nautobot demo host owns 8080, and the two are
meant to be runnable side by side.

The fastest confirmation that it works, using a token from the table below:

```bash
TOKEN="frisian-demo-readonly-token-public-do-not-reuse" \
ROUTE="mcp/read-only" \
BASE_URL="http://127.0.0.1:8081" \
../common/mcp-clients/curl-tools-list.sh
```

Five tools come back. The walkthrough below is what makes that interesting.

## What the first boot looks like, and why it looks like a build

It does not build anything. `docker-compose.yml` has no `build:` key at all —
building requires the explicit `-f docker-compose.build.yml` chain further
down. But two things about the startup output reliably read as a local build
the first time you see them, so they are worth naming.

### 1. A wall of `mkdir` and `changed ownership`

```text
mkdir: created directory '/usr/src/paperless/media/documents/originals'
changed ownership of '/usr/src/paperless/data' from root:root to paperless:paperless
changed ownership of '/usr/src/paperless/media' from root:root to paperless:paperless
```

That is the estate being restored, and it happens on **every** start rather
than only the first.

Paperless's image uses s6-overlay, which narrates each init step, and this host
mounts all four Paperless data directories as RAM disks. So those directories
genuinely are absent at every boot and genuinely do get recreated and chowned —
`init-folders` is doing real work, not replaying a cached image layer. The same
mechanism is what makes `docker compose restart` hand you a clean archive in
about twenty seconds, so the noise is the feature's receipt.

It is louder than the Nautobot host for that reason: there, only the database
is a RAM disk.

### 2. No `Pulling from ghcr.io` lines

Compose's default `pull_policy` is `missing` — it contacts the registry only
when the tag is not already in your local image store. On an empty cache you
get what you would expect:

```text
Image ghcr.io/frisian-mcp/demo-paperless-db:v0.1.0-pre  Pulling
Image ghcr.io/frisian-mcp/demo-paperless:v0.1.0-pre     Pulling
...
Image ghcr.io/frisian-mcp/demo-paperless:v0.1.0-pre     Pulled
```

Measured cold, with both images removed first: **28 seconds** from
`docker compose up` to a healthy stack, pull included.

**If you see no pull lines, the tag was already in your store.** The case that
surprises people: on Docker Desktop with the **containerd image store**
enabled, `docker buildx build --push` writes the image into the local store as
well as the registry. So whoever ran `publish.sh --push` on a machine has the
images cached there as a side effect and will never see a pull on that machine
again. On the classic image store `--push` leaves nothing behind and the pull
happens normally — which is why two people can run the same command and see
different output.

To settle it either way, ask the image where it came from:

```bash
docker image inspect ghcr.io/frisian-mcp/demo-paperless:v0.1.0-pre \
  --format '{{.RepoDigests}}'
```

A digest means it came from the registry. An image Docker built locally has an
**empty** `RepoDigests` list, always — so this is a definitive answer rather
than an inference from the log output.

## Every start is a fresh archive

Both halves of the demo archive are restored **every time the stack starts** —
the first `docker compose up`, every `up` after that, and `docker compose
restart` too.

- the **database** is restored by the db image's initdb hook, because its
  `PGDATA` is a RAM disk rather than a volume
- the **document files** are unpacked from a tarball baked into the application
  image by `/custom-cont-init.d/10-restore-demo-estate.sh`, because
  `/usr/src/paperless/media` is a RAM disk for the same reason

The practical consequence is the one to remember: **changes you make to the
demo archive do not survive a restart.** Retag a document, then restart, and
the original tags are back. Nothing you do here is precious, which is the
intended trade for a demo whose archive is the product.

That also means getting back to a clean archive needs no special command:

```bash
docker compose restart
```

It is fast. Measured on a warm machine with both images already present:
**22 seconds** from `docker compose up` to a stack answering requests. The
database restore is a 41 KB dump and is effectively instantaneous; the
application's own init — migrations check, search-index rebuild from the
database, media restore — is about **7 seconds**, and the rest is the
application starting. The first run also has to download the images, which
depends on your connection and is usually the longest part.

Leaving those volumes undeclared would NOT have the same effect. The upstream
images declare `VOLUME` on `PGDATA` and on all four Paperless data directories,
so Docker creates **anonymous** volumes regardless and Compose preserves them
across container recreation — including an `up` onto a changed image. Measured
on the Nautobot host, same harness both ways: with an anonymous volume the
restore is skipped on `restart` and on upgrade; with a tmpfs it runs every
time.

The demo's change log starts empty on purpose. The audit records from building
this archive are truncated before the image is baked, because they are a
build-time trail rather than part of the demo. Changes you make while using the
demo are logged normally.

## The demo identities

Three identities, three doors, three tier ceilings. All tokens are fixed,
published constants — reproducible in every build, and not secrets.

| identity | door | tier ceiling | Django permissions |
|---|---|---|---|
| `demo-readonly` | `mcp/read-only` | `read` | `view` on the scoped archive |
| `demo-editor` | `mcp/read-write` | `read_write` | `view` on all scoped models; **write on `Document` and `Tag` only** |
| `demo-admin` | `mcp/ops` | `admin` | superuser |

```text
demo-readonly   Bearer frisian-demo-readonly-token-public-do-not-reuse
demo-editor     Bearer frisian-demo-editor-token-public-do-not-reuse
demo-admin      Bearer frisian-demo-admin-token-public-do-not-reuse
```

The `readonly` and `admin` tokens are deliberately the same strings the
Nautobot host uses. An identity that means the same thing on both demo surfaces
should not need a different line in a client config.

The same accounts log into the web UI at `http://127.0.0.1:8081` with the
published password `frisian-demo-public-password`.

**`demo-editor` is the deliberately interesting one.** Its door permits the
write tier across five resource groups; its own permissions permit writes to
two models. The door's ceiling and the principal's grants are independent
controls, and you can only tell them apart by watching an identity be refused
something its door plainly allows. A refusal there is the feature.

`demo-admin` is a superuser, so it bypasses per-model permissions entirely.
That is the right contrast for the admin door, but it means the admin identity
demonstrates the tier ceiling rather than the permission model. Do not read it
as a scoped account.

## Demo walkthrough

The point of frisian-mcp is that one server shows a **different tool surface to
different agent identities**. There are two separate mechanisms doing that, and
the walkthrough shows each one where it is actually visible.

### 1. The dispatcher pattern — 7 tools instead of 117

Paperless-ngx exposes 117 ViewSet actions in this configuration — the number
the server prints at startup. Handed to an agent raw, that is tens of thousands
of tokens of tool schema before it has done anything.

`FRISIAN_MCP_DISPATCH_GROUPS` in `config/paperless_frisian_mcp.py` bundles them
into seven topic-level tools:

| group | what is in it |
|---|---|
| `documents` | the archive itself — search, metadata, preview, download, notes |
| `classification` | correspondents, document types, tags, storage paths, custom fields |
| `mail` | email ingestion accounts and rules |
| `workflow` | automation triggers and actions |
| `sharing` | public share links |
| `system` | users, groups, instance configuration |
| `monitoring` | tasks, logs, saved views |

An agent calls a group tool with `action: "help"` to learn what is inside it.
That is progressive discovery: the catalogue is cheap, the detail is on demand.

### 2. Route carving — what a door does not have

Each door carries a different number of groups, and the **middle** door carries
the fewest:

| door | groups | what is missing |
|---|---|---|
| `mcp/read-only` | 5 | `system`, `sharing` |
| `mcp/read-write` | **4** | `system`, `sharing`, and `workflow` |
| `mcp/ops` | 7 | nothing |

```bash
for d in read-only:readonly read-write:editor ops:admin; do
  TOKEN="frisian-demo-${d#*:}-token-public-do-not-reuse" ROUTE="mcp/${d%%:*}" \
    BASE_URL="http://127.0.0.1:8081" ../common/mcp-clients/curl-tools-list.sh \
    | grep -o '"name": "[a-z_]*"' | wc -l
done
```

The important part is *how* the missing ones are missing: **absent from a route
is byte-identical to never-registered.** A caller on a scoped door cannot tell
a carved-out group from one that does not exist in this Paperless at all. There
is no "403 forbidden" to probe against and no error message that confirms the
resource is there.

And this is a property of the *route*, not of the caller. Ask the read-write
door as the superuser and `workflow` is still gone:

```bash
TOKEN="frisian-demo-admin-token-public-do-not-reuse" ROUTE="mcp/read-write" \
  BASE_URL="http://127.0.0.1:8081" ../common/mcp-clients/curl-tools-list.sh
```

Why the write-capable door is the *smallest* is §5.

The same mechanism operates one level down. `mail` is present on the scoped
doors, but `mailaccount` is not in it:

```bash
TOKEN="frisian-demo-readonly-token-public-do-not-reuse" ROUTE="mcp/read-only" \
  BASE_URL="http://127.0.0.1:8081" ../common/mcp-clients/curl-help.sh mail
```

A `MailAccount` stores an IMAP password. It is credential storage wearing a
configuration object, so it never leaves the admin door.

### 3. The read ceiling — a tier, not a permission

Connect the **admin** token to the **read-only** door:

```bash
TOKEN="frisian-demo-admin-token-public-do-not-reuse" ROUTE="mcp/read-only" \
  BASE_URL="http://127.0.0.1:8081" ../common/mcp-clients/curl-help.sh classification
```

A superuser, and there is still no `create`, `update` or `destroy` in the
action list. The route's tier ceiling filters the surface regardless of who is
asking. The ceiling only ever **narrows** — it never grants, so a read-tier
token on the admin door is still a read-tier token.

### 4. Permission-aware discovery — the same door, two identities

This is the one to spend time on, because it is the mechanism people expect to
have to build themselves.

`demo-editor` connects to the read-write door. Its door permits the write tier
across all five groups. Ask its `classification` dispatcher what it can do:

```bash
TOKEN="frisian-demo-editor-token-public-do-not-reuse" ROUTE="mcp/read-write" \
  BASE_URL="http://127.0.0.1:8081" ../common/mcp-clients/curl-help.sh classification
```

`tag` has write actions. `correspondent`, `documenttype`, `storagepath` and
`customfield` — in the **same dispatcher**, through the **same door** — do not.
Nothing about the route distinguishes them. What distinguishes them is that
this principal holds `documents.change_tag` and does not hold
`documents.change_correspondent`, and the action enum is rebuilt per request
from `user.has_perm()`.

Prove it end to end. This works:

```bash
curl -sS -X POST http://127.0.0.1:8081/mcp/read-write/ \
  -H "Authorization: Bearer frisian-demo-editor-token-public-do-not-reuse" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"classification",
       "arguments":{"resource":"tag","action":"partial_update",
                    "params":{"id":1,"name":"paid-in-full"}}}}'
```

and this does not, from the same identity through the same door:

```bash
curl -sS -X POST http://127.0.0.1:8081/mcp/read-write/ \
  -H "Authorization: Bearer frisian-demo-editor-token-public-do-not-reuse" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"classification",
       "arguments":{"resource":"correspondent","action":"partial_update",
                    "params":{"id":1,"name":"should-never-apply"}}}}'
```

**That refusal is the feature.** If you find yourself widening `demo-editor`'s
grant to make it succeed, the demo has stopped demonstrating anything.

### 5. More tier does not mean more surface

The read-write door carries **more** denials than the read-only door — five
groups against four. The `workflow` group is browsable on the read-only door
and absent from the read-write one.

A `WorkflowAction` carries webhook URLs, webhook bodies and headers, and email
recipients, and the workflow engine fires them on document events. Creating one
is server-side request forgery with a form in front of it. On the read door
those writes are already impossible — the `read` ceiling filters them out —
while `list` and `retrieve` remain, so the automation catalogue stays
browsable. Denying the group on both doors would throw that away for no
security gain.

## The demo archive

24 documents across six correspondents, six document types, eight tags, three
storage paths and three custom fields, plus two saved views and one workflow.

Every document is **fiction**: the correspondents, addresses, account numbers
and amounts are invented for this demo and correspond to no real person or
organisation. They are born-digital PDFs with a real text layer, so full-text
search works and nothing needs OCR.

The whole archive is generated from `seed/corpus.py` and filed by
`seed/build_estate.py`, both committed here. Rebuilding it is one command:

```bash
FRISIAN_MCP_LOCAL_WHEEL=<wheel> ./seed/seed.sh
```

That is a real difference from the Nautobot host, whose golden dump is produced
outside this repository because it descends from a live instance. This archive
has no such ancestry, so it can be — and is — built in the open.

## Connecting an agent

Ready-to-paste configurations ship next to this file:

| client | file |
|---|---|
| Claude Code | [`.mcp.json`](.mcp.json) |
| Cursor | [`.cursor/mcp.json`](.cursor/mcp.json) |
| Codex | [`.codex/config.toml`](.codex/config.toml) |

Each declares all three doors, because the demo is the difference between them.
See [`GETTING-STARTED.md`](GETTING-STARTED.md) for a first session that is
worth watching.

## Building the images yourself

The default path pulls prebuilt images from GHCR. To build both locally:

```bash
FRISIAN_MCP_LOCAL_WHEEL=<wheel> ./seed/seed.sh
docker compose -f docker-compose.yml -f docker-compose.build.yml up --build
```

The seed step is not optional the first time: both images bake an artifact that
step produces, and neither artifact is committed to git.

## Binary responses are not supported, on purpose

Paperless is a document archive, so the first thing many people try is
`document.download`. It does not work, and it is not going to:

```json
{"error": "Failed to serialise response: 'utf-8' codec can't decode byte 0xbf
           in position 10: invalid start byte", "status_code": 500}
```

`preview`, `thumb` and `download` all fail the same way — the response layer
runs file bytes through a UTF-8 decode.

**This is a scope decision, not a bug to report.** Returning binary payloads
over MCP is not a subject the MCP Contributors Groups have open — neither the
Interest Group nor the Working Group — so there is no specified behaviour to
implement against. frisian-mcp does not support it, deliberately, because
handing arbitrary binary content to a host agent is a hazard we are not
prepared to take on without a specification behind it.

Two consequences worth knowing before you plan around them:

- **The actions stay visible.** They are discovered from the ViewSet like every
  other action, so an agent can see `download` and try it. The failure is at
  serialisation, not at discovery. If that matters for your deployment, deny
  the resource on the route rather than expecting the action to disappear.
- **The metadata is fine.** Everything *about* a document — `metadata`,
  `notes`, `history`, `suggestions`, full-text `query` with scored highlights —
  works normally. It is only the file bytes that do not cross the boundary.

If you need the file itself, fetch it from Paperless's own REST API with a
Paperless token. That path is unchanged and unaffected by frisian-mcp.

## What is deliberately not here

- **No Paperless source.** The application image is built `FROM` the published
  upstream image. Nothing is vendored.
- **No ShareLink, no MailAccount, no webhook workflow** in the archive. Those
  are the resources the scoped routes carve out, and shipping live examples
  would hand anyone who reaches the admin door a working outbound request and a
  public document URL. A carve-out is demonstrated by absence from a door,
  which does not require an instance to exist.
- **No unauthenticated mode.** See the posture note at the top.
- **No binary responses.** `document.preview`, `document.thumb` and
  `document.download` are auto-discovered from the ViewSet and are visible in
  the dispatcher, but they do not return a file. Calling one gets an error, and
  that is the intended behaviour rather than a defect — see below.
