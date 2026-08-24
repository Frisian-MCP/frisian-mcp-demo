# Nautobot demo host

A clone-and-run frisian-mcp demo against a real Nautobot instance, carrying a
pre-built network estate and three pre-provisioned agent identities.

This host ships two matched images: the Nautobot application image and the
pre-seeded PostgreSQL image.

## Safety: localhost only

**This demo ships known, published credentials by design.** Every token,
password, and HMAC key in this directory is printed in the open, committed to
this repository, and baked into the published images. They are what make the
demo work with no setup step, and they are the reason it is not safe to expose.

Treat this stack as public the moment it is reachable by anything but you.

The compose file binds the HTTP port to `127.0.0.1`. That is a control, not a
default anyone should tidy up: binding to `0.0.0.0` publishes an instance whose
administrative credentials are in a public git repository. Change
`DEMO_BIND_HOST` only on a network you control, and rotate everything first if
you intend to keep the instance.

`ALLOWED_HOSTS` is a second gate behind that one. It ships as
`localhost 127.0.0.1 [::1]`, so reaching the demo under any other hostname
fails at the Django layer even if the bind address is widened. Both have to be
changed deliberately; neither changes by accident.

### The posture is locked

Authentication is required on every door. Unauthenticated requests are refused,
not served a reduced view:

```console
$ curl -i -X POST http://127.0.0.1:8080/mcp/read-only/ -d '{}'
HTTP/1.1 401 Unauthorized
```

There is no unauthenticated walk-up mode in this image, and the setting that
enforces it is not one to experiment with — removing it does not loosen the
demo slightly, it republishes an open read door onto the whole estate.

## Quickstart

From the repository root:

```bash
cd nautobot
docker compose up
```

No flags, no copied `.env`, no repository-root setup step. The committed `.env`
holds published demo defaults and is part of the quickstart contract.

When the stack is healthy the local endpoint is:

```text
http://127.0.0.1:8080
```

The fastest confirmation that it works, using a token from the table below:

```bash
TOKEN="frisian-demo-readonly-token-public-do-not-reuse" \
ROUTE="mcp/read-only" \
../common/mcp-clients/curl-tools-list.sh
```

Twelve tools come back. The walkthrough below is what makes that interesting.

## Every start is a fresh estate

The database image restores its baked demo estate **every time the database
starts** — the first `docker compose up`, every `up` after that, and
`docker compose restart` too.

The practical consequence is the one to remember: **changes you make to the
demo estate do not survive a restart.** Rename a device, then restart, and the
original name is back. Nothing you do here is precious, which is the intended
trade for a demo whose estate is the product.

That also means getting back to a clean estate needs no special command:

```bash
docker compose restart
```

The database's data directory is a RAM disk rather than a volume, so there is
no state for Docker to carry across a restart and the restore always runs. This
is deliberate: it is what guarantees that a newer `DEMO_TAG` gets the database
that matches it, rather than a new application image on top of an old database.

The restore itself takes **about four seconds** — the demo estate is small.
While it runs, the `db` service is intentionally not healthy and the
application waits behind the compose healthcheck.

Most of the startup time is the application, not the database. From
`docker compose up` to a stack that answers requests is **about a minute** once
both images are present locally. The first run also has to download them, which
depends on your connection and is usually the longest part.

The demo's change log starts empty on purpose. The object-change history from
building this estate is truncated before the public image is baked, because it
is a build-time audit trail rather than part of the demo. Changes you make
while using the demo are logged normally.

## The demo identities

Three identities, three doors, three tier ceilings. All tokens are fixed,
published constants — reproducible in every build, and not secrets.

| identity | door | tier ceiling | Django permissions |
|---|---|---|---|
| `demo-readonly` | `mcp/read-only` | `read` | `view` on the scoped estate |
| `demo-netops` | `mcp/read-write` | `read_write` | `view` on all scoped apps; **write on `dcim` and `ipam` only** |
| `demo-admin` | `mcp/admin` | `admin` | superuser |

```text
demo-readonly   Bearer frisian-demo-readonly-token-public-do-not-reuse
demo-netops     Bearer frisian-demo-netops-token-public-do-not-reuse
demo-admin      Bearer frisian-demo-admin-token-public-do-not-reuse
```

The same accounts log into the web UI at `http://127.0.0.1:8080` with the
published password `frisian-demo-public-password`.

**`demo-netops` is the deliberately interesting one.** Its door permits the
write tier across all twelve scoped resource groups; its own permissions permit
writes to two of them. The door's ceiling and the principal's grants are
independent controls, and you can only tell them apart by watching an identity
be refused something its door plainly allows. A refusal there is the feature.

`demo-admin` is a superuser, so it bypasses per-object permissions entirely.
That is the right contrast for the admin door, but it means the admin identity
demonstrates the tier ceiling rather than the permission model. Do not read it
as a scoped account.

## Demo walkthrough

The point of frisian-mcp is that one server shows a **different tool surface to
different agent identities**. There are two separate mechanisms doing that, and
the walkthrough shows each one where it is actually visible.

### Do not compare `tools/list` lengths on the scoped doors

Start here, because it is the intuitive move and it proves nothing:

```bash
# read-only door, demo-readonly
TOKEN="frisian-demo-readonly-token-public-do-not-reuse" ROUTE="mcp/read-only" \
  ../common/mcp-clients/curl-tools-list.sh

# read-write door, demo-netops
TOKEN="frisian-demo-netops-token-public-do-not-reuse" ROUTE="mcp/read-write" \
  ../common/mcp-clients/curl-tools-list.sh
```

Both return **12 tools, with identical names**. That is correct and expected —
but not for the reason it first appears.

Two filters run in series. The route's allow-list fixes the **candidate set**,
and permission-aware discovery then filters **within** that set, per identity.
On the scoped doors the allow-list has already removed almost everything these
two identities differ on, so the second filter has almost nothing left to do and
the result looks like a property of the route alone. It is not.

The same door, asked by `demo-admin`, returns **13**:

```text
mcp/read-only    demo-readonly   12
mcp/read-write   demo-netops     12
mcp/read-only    demo-admin      13     <- load_balancers
```

`load_balancers` is on that door's allow-list, so the group is **mounted for
everyone** — it is hidden from `tools/list` for identities that cannot use it,
not absent. Invoking it as `demo-readonly` proves the difference, because a
refusal is not the same answer as a missing route:

```text
demo-readonly   403  "You do not have permission to use 'loadbalancerpool'/'list'"
demo-admin      200
```

So the per-identity difference is real on every door. On the scoped doors it is
just mostly masked, and the place it shows plainly is one level down — inside
each dispatcher's action list.

### 1. Same door, same token, two different answers

Ask a dispatcher what it will let you do, with `action: "help"`:

```bash
TOKEN="frisian-demo-netops-token-public-do-not-reuse" ROUTE="mcp/read-write" \
  ../common/mcp-clients/curl-help.sh dcim

TOKEN="frisian-demo-netops-token-public-do-not-reuse" ROUTE="mcp/read-write" \
  ../common/mcp-clients/curl-help.sh dns
```

One identity, one token, one door — and two different shapes:

```text
dcim   device      list  retrieve  notes  napalm  create  update  partial_update  ...
dns    dnszone     list  retrieve  notes
       arecord     list  retrieve  notes
```

`demo-netops` holds a `read_write` token on a `read_write` door, and still has
no way to write a DNS zone, because its permissions only grant writes on `dcim`
and `ipam`. The write actions are **absent from the listing**, not offered and
then refused. An agent planning against this surface never proposes the call.

That single contrast is the product. Everything else is a variation on it.

### 2. Same group, two identities

```bash
TOKEN="frisian-demo-readonly-token-public-do-not-reuse" ROUTE="mcp/read-only" \
  ../common/mcp-clients/curl-help.sh dcim
```

```text
demo-readonly    device    list  retrieve  notes  napalm
demo-netops      device    list  retrieve  notes  napalm  create  update  ...
```

Same resource, same server, different caller.

### 3. More privilege does not mean more surface

Compare the `extras` group across the two scoped doors:

```text
mcp/read-only     job    list  retrieve  notes  variables
mcp/read-write    job    ABSENT
```

The **more** privileged door deliberately carries **less**. Running a Nautobot
job is arbitrary code execution, so the resource is withheld from the door
where the write tier would make it reachable, while the read-only door keeps
the job catalogue browsable. Credential material is absent from both.

### 4. What the scoped doors hide is really there

```bash
TOKEN="frisian-demo-admin-token-public-do-not-reuse" ROUTE="mcp/admin" \
  ../common/mcp-clients/curl-tools-list.sh
```

47 tools, against 12 on the scoped doors — the full ungrouped surface,
including everything the carve-outs removed.

The admin door is where the per-identity filtering becomes *obvious*, because
it applies no route carve of its own — nothing has narrowed the candidate set
first, so the whole spread is on display. The same three tokens against that one
door:

```text
demo-readonly     23 tools
demo-netops       38 tools
demo-admin        47 tools
```

Same URL, same request, three different manifests.

### 5. The doors are real

```console
$ curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8080/mcp/ -d '{}'
404
```

There is no catch-all mount behind the three named doors. A route that is not
mounted is absent rather than merely locked.

## Known limitations

**Bulk actions are listed but not invocable through the dispatcher.** A `help`
response may include `bulk_update` and `bulk_partial_update` for a resource you
can write:

```text
dcim/device    ... create  update  partial_update  bulk_update  bulk_partial_update
```

Calling one returns `-32602`, because a dispatcher's `params` is typed as an
object and these actions require a list body:

```text
"code": -32602, "message": "Invalid arguments", "data": "[] is not of type 'object'"
```

Use the single-object actions — `create`, `update`, `partial_update` — one call
per object.

## The demo estate

A small multi-site enterprise, built entirely through MCP calls by agents using
the scoped identities above. It is fictional, and it is the part of the demo
worth exploring:

- **DC1** — primary data centre: 2 spine, 4 leaf, 1 edge router, 1 firewall
- **DC2** — secondary site: 2 spine, 1 leaf, 1 edge router
- **BR1** — branch office: 1 router, 1 access switch

14 devices and 424 interfaces across 4 locations and 4 racks, with two leaves
carrying a full 48 ports each. Every leaf uplinks to both spines from its top
ports, the edge router and firewall are patched in, and the branch router is
cabled to its access switch — 14 cables in total.

On top of that: 10 prefixes, 6 VLANs, and 14 addresses bound to real
interfaces; 2 tenants; 2 carrier circuits with 4 terminations joining DC1 to
DC2 and DC1 to the branch; a live BGP peering between the two edge ASNs; one
DNS zone with records resolving to addresses that exist in the estate; and
golden-config settings with a compliance feature and rule.

The two full-port leaves are load-bearing rather than padding. Listing their
interfaces is what exercises the read-side features this package exists for —
pagination, the lean response envelope, and heavy-response negotiation, which
begins at around 30 interfaces.

## Connecting an MCP client

Copy a block from
[`../common/mcp-clients/nautobot.mcp.json.template`](../common/mcp-clients/nautobot.mcp.json.template)
into your client configuration. The tokens are real and work as printed.

Connect one identity at a time when demonstrating the contrast, so that what
changes between two `help` calls is the identity and nothing else.

### OAuth

There are two ways in, and which one you use determines how much you get.

**Self-serve OAuth gets you `read`.** The read-write and admin surfaces are
reached only with the provisioned static tokens above. That is the scoping
lesson rather than a shortcoming: a client that walks up and asks for access
lands at the floor, and wider authority is something an operator hands out.

#### Static tokens

The supported path for all three tiers, and what the shipped client
configurations use. Paste a block from
[`../common/mcp-clients/nautobot.mcp.json.template`](../common/mcp-clients/nautobot.mcp.json.template)
and connect.

#### Browser-based connect

One OAuth client is pre-registered. Its ID and secret are published, like
everything else here:

```text
client_id      frisian-demo-public-client-id
client_secret  frisian-demo-public-client-secret-do-not-reuse
```

Registered redirect URIs:

```text
https://claude.ai/api/mcp/auth_callback
http://localhost:8080/oauth/callback
http://127.0.0.1:8080/oauth/callback
```

A spec-compliant client that receives a `401` follows the standard discovery
cascade to find the authorization server, so it does not have to guess:

```console
$ curl -s http://localhost:8080/.well-known/oauth-authorization-server
{"authorization_endpoint": "http://localhost:8080/oauth/authorize/", ...}
```

An approval screen always renders before anything is issued — automatic
approval is off, so consent cannot be skipped or replayed from a stored
decision:

```console
$ curl -s -o /dev/null -w '%{http_code}\n' \
    'http://localhost:8080/oauth/authorize/?client_id=frisian-demo-public-client-id&...'
200      # "An application is requesting access to this MCP server."  Allow / Deny
```

Both halves of that check refuse properly:

```text
unknown client_id                        400  {"error": "invalid_client"}
known client, unregistered redirect_uri  400  {"error": "invalid_redirect_uri"}
```

There is no separate login step: approving grants a token that acts as the
`demo-readonly` identity, at the `read` tier. The client is also restricted to
the authorization-code grant, so its published ID and secret cannot be replayed
as a service-to-service credential to obtain a token with no approval screen in
the way.

Use `localhost` rather than `127.0.0.1` for the OAuth endpoints; that is the
issuer the server advertises, and the two are not interchangeable to a client
matching redirect URIs.

> Whether a given third-party connector uses the exact callback URL registered
> above is not something this repository can verify. The server side is correct
> and both controls refuse properly. If a connect attempt fails on the redirect,
> the registered URI list is the place to look.

No access token is ever baked into an image. They expire, so a baked one would
be dead on arrival.

## Image pinning

`DEMO_TAG` pins both images to the same version:

```text
ghcr.io/frisian-mcp/demo-nautobot:${DEMO_TAG}
ghcr.io/frisian-mcp/demo-nautobot-db:${DEMO_TAG}
```

The committed default is `DEMO_TAG=v0.1.0`.

**There is no `latest` tag.** The application image and the database image are
a matched pair — the database contains identities whose tokens are verified by
a key the application image carries, so running two different tags is
unsupported and fails in ways that look like broken authentication.

Changing `DEMO_TAG` needs no special ceremony — `docker compose up` is enough.
Because the database keeps nothing across a start, a new tag always brings up
its own matching estate rather than a new application image on top of the
previous one. That is the reason the data directory is a RAM disk.

## Environment

You do not need to create `.env`; it is committed so that a fresh clone works
with `docker compose up`.

| Variable | Default | Meaning |
|---|---|---|
| `DEMO_TAG` | `v0.1.0` | Single tag for both demo images |
| `DEMO_BIND_HOST` | `127.0.0.1` | Host interface for the published HTTP port |
| `DEMO_HTTP_PORT` | `8080` | Host HTTP port |
| `NAUTOBOT_ALLOWED_HOSTS` | `localhost 127.0.0.1 [::1]` | Hostnames Django will answer to |
| `POSTGRES_DB` / `POSTGRES_USER` | `nautobot` | Database name and role required by the dump |
| `FRISIAN_MCP_HMAC_KEY` | fixed demo value | Key the baked demo tokens are verified against |

`FRISIAN_MCP_HMAC_KEY` is public by design and must not be changed: the demo
tokens are stored as digests computed under that key, so replacing it
invalidates all three identities at once, silently.

`NAUTOBOT_SECRET_KEY` is deliberately absent. It is generated per deployment on
first boot and persisted to the `demo_state` volume, so no two deployments of
this public image share a signing key — the base image ships a hardcoded one,
and a published signing key is not a signing key.

For the full annotated reference, read [`.env.example`](.env.example).

## Local build

The default path pulls both prebuilt images, and is the one to use unless you
are changing the image contents.

**The application image builds from a clean clone. The database image does
not** — it bakes in `db/demo.sql.gz`, and that artifact is deliberately not
committed. It is a binary blob built by CI after the estate's inherited
credentials have been reset, and a public repository is not the place for it.
So on a fresh clone:

```bash
# application image: builds
docker compose -f docker-compose.yml -f docker-compose.build.yml build nautobot

# database image: fails, and this is expected
#   COPY db/demo.sql.gz  ->  "/db/demo.sql.gz": not found
```

Pull the database image rather than building it, which is what the default
`docker compose up` already does. If you genuinely need to build it — because
you are seeding a different estate — put your own `demo.sql.gz` at
`nautobot/db/` first, and the build will pick it up.

The `COPY` failing is the intended behaviour: a database image built without
that file would start empty, and an empty demo that looks like a working one is
worse than a build error.

## Stop and reset

```bash
docker compose restart   # restart in place — the estate is RESTORED
docker compose down      # stop and remove the containers
docker compose down -v   # stop and discard local state as well
```

All three return the estate to its baked state on the next start; the database
keeps nothing across a restart by design. `down -v` additionally discards the
generated secret key.

Browser sessions do not survive **any** of them — the session table lives in
the database, so it goes with everything else and you log in again. The demo
tokens always keep working, because they are verified against the fixed HMAC
key rather than the per-deployment secret key.

See [Every start is a fresh estate](#every-start-is-a-fresh-estate).
