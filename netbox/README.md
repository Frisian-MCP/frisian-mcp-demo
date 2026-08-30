# NetBox demo host

A pre-seeded NetBox running behind [frisian-mcp](https://github.com/Frisian-MCP/frisian-mcp),
with a small network estate, three identities and **three separate MCP doors**.

It exists to make one thing concrete: an MCP tool surface that changes shape
depending on which door you knock on and who you are when you knock.

**This is the host that demonstrates the route ceiling.** The Nautobot and
Paperless demos give three identities one mount point. This one gives three
identities *and* three mount points, each with its own tier ceiling — so you
can send the same admin token at two URLs and watch it be offered less on one
of them. If you only have time for one demo host, and what you want to
understand is per-route permissions, it is this one.

---

## Safety: localhost only

Every credential in this repository is published, fixed and identical on every
machine that runs it. The compose file binds to `127.0.0.1` for that reason.

Do not put this on a network anyone else can reach. It is not a hardened
deployment and is not meant to become one — it is a demonstration whose
passwords are printed in its own README.

### The posture is locked

The configuration is deliberately restrictive, and the restrictions are the
demonstration rather than an inconvenience to work around:

| setting | value | why |
|---|---|---|
| `FRISIAN_MCP_PERMISSION_CLASSES` | `IsAuthenticated` | anonymous is `401` on every door |
| `FRISIAN_MCP_OAUTH_REGISTRATION_OPEN` | `False` | no walk-up dynamic client registration |
| `FRISIAN_MCP_OAUTH_AUTO_APPROVE` | `False` | consent is never implied |
| `FRISIAN_MCP_OAUTH_PKCE_DEFAULT_PERMISSION` | `read` | a walk-up client lands at the lowest tier |
| `FRISIAN_MCP_OAUTH_TOKEN_EXPIRY_SECONDS` | `86400` | 24h, not a year |
| `PERMISSION_AWARE_DISCOVERY` | on | you are not offered what you cannot use |

If you change one to make something work, you have turned off part of what you
came to see.

---

## Quickstart

```bash
cd netbox
docker compose up
```

Exactly the same entry path as the Nautobot and Paperless hosts — no flag, no
profile, no `-f` chain. Both images are pulled from GHCR; nothing builds
locally. `docker compose up -d` works identically if you would rather have the
terminal back.

Then open **<http://127.0.0.1:8083/>**.

Log in as any of the three identities below — the password is the same for all
of them:

| username | password |
|---|---|
| `demo-readonly` | `frisian-demo-public-password` |
| `demo-netops` | `frisian-demo-public-password` |
| `demo-admin` | `frisian-demo-public-password` |

The GUI matters here. Everything an agent tells you through MCP is visible in
the web interface too, so you can check its answers against the same data
rather than taking them on trust — and when a write is refused, you can confirm
in the UI that nothing changed.

### One restart during first boot is normal — and why nothing here uses `--wait`

The `netbox` container restarts itself once while it waits for Postgres to
accept connections. In the foreground you will see it go down and come back.
That is part of starting, not a failure.

It matters if you script the boot: `docker compose up -d --wait` reads that
restart as a failed start and gives up on a stack that is coming up correctly.
CI and `common/ci/acceptance-netbox.sh` poll for the healthcheck instead. The
quickstart above is unaffected — it does not use `--wait`, and neither do the
other hosts' quickstarts.

First boot takes a couple of minutes. Watch it with:

```bash
docker compose logs -f netbox
```

---

## Every start is a fresh estate

`PGDATA` is a **tmpfs**. The database lives in RAM and is restored from the
baked dump on every container start — including `docker compose restart`, not
only `up`.

Two consequences worth knowing before you explore:

* **Anything you change goes away on restart.** That is the point: break the
  estate, then put it back with `docker compose restart`. Restore takes about
  four seconds.
* **Every browser session ends on restart**, because Django sessions are stored
  in the database. You will be logged out. That is not a bug.

---

## The demo identities

Three identities, three doors, and the pairing is not fixed — any token works
on any door. Sending the wrong one at the wrong door on purpose is the most
informative thing you can do here.

| identity | token tier | its door | what it can actually do |
|---|---|---|---|
| `demo-readonly` | `read` | `/api/mcp/read-only/` | view the estate |
| `demo-netops` | `read_write` | `/api/mcp/read-write/` | view everything; **add and change** in `dcim` and `ipam` only |
| `demo-admin` | `admin` | `/api/mcp/ops/` | superuser |

The tokens are fixed constants, published on purpose:

```
frisian-demo-readonly-token-public-do-not-reuse
frisian-demo-netops-token-public-do-not-reuse
frisian-demo-admin-token-public-do-not-reuse
```

### `demo-netops` is the interesting one

Its door permits the write tier across eight dispatch groups. The identity can
write in two. And within those two it holds **add and change but not delete**.

So there are three different limits stacked on one caller, and each is visible
separately:

* `tenancy` offers it no `create` — the **grant** stops it, though the door
  would allow it.
* `dcim` offers it no `destroy` — the **grant** again, one action finer.
* On `/api/mcp/read-only/`, `dcim` offers it no writes at all — the **door**
  stops it, regardless of grant.

---

## The three doors

```python
FRISIAN_MCP_ROUTES = {
    "default":  {"path": "api/mcp/read-only",  "highest_tier": "read"},
    "elevated": {"path": "api/mcp/read-write", "highest_tier": "read_write"},
    "admin":    {"path": "api/mcp/ops",        "highest_tier": "admin"},
}
```

`highest_tier` is a **ceiling, not an assignment**. It caps what any caller can
reach through that path; it never grants anything. A caller's own permissions
then narrow it further. Both apply, in that order.

### The admin door is `ops`, not `admin`

MCP clients — Claude, GPT and Grok have all been observed doing this — strip an
`admin` suffix from a URL and silently retry the bare path. A door at
`/api/mcp/admin` therefore lands the caller on `/api/mcp/` with a different
ceiling and no error. The route *key* can be `admin`; the *path* must not end
in it.

### NetBox mounts these differently from every other host

On other Django hosts frisian-mcp mounts its own URLs from `AppConfig.ready()`.
NetBox routes third-party URLs through its plugin system instead, so the
wrapper in `plugin/frisian_mcp_netbox/` does the mounting — by calling the
package's own `_install_route_urls()`.

That detail matters because of how it can fail. A wrapper that mounts
`include("frisian_mcp.urls")` once per path produces three URLs that all answer,
all look correct, and all serve the **full unfiltered registry** — no ceiling
anywhere. Three doors that enforce nothing is a worse outcome than three 404s,
because nothing about it looks broken.

Both `publish.sh` and CI refuse to build a wrapper that does not call
`_install_route_urls()`, and `common/ci/acceptance-netbox.sh` proves the
ceiling behaviourally rather than trusting the grep.

---

## Demo walkthrough

Point a client at all three doors using
[`../common/mcp-clients/netbox.mcp.json.template`](../common/mcp-clients/netbox.mcp.json.template),
or use `curl`. `GETTING-STARTED.md` walks the whole thing in order; this is the
short version of what there is to see.

### 1. The dispatcher pattern — 10 tools instead of 1,176

NetBox exposes an enormous API. frisian-mcp registers **1,176 tools** across it
and bundles them into **10 topic-level dispatchers**:

| group | resources |
|---|---|
| `dcim` | 47 |
| `extras` | 21 |
| `ipam` | 18 |
| `core` | 12 |
| `circuits` | 11 |
| `vpn` | 10 |
| `users` | 7 |
| `virtualization` | 7 |
| `tenancy` | 6 |
| `wireless` | 3 |

142 resources in ten groups, carrying 1,176 tools between them.

A client loads ten tool schemas on connection instead of eleven hundred. Ask
any dispatcher for `help` and it tells you the resources and actions available
**to you, on this door** — which is where every difference below shows up.

### 2. The route ceiling — same token, two doors

The demonstration. Send the **admin** token at two doors and ask the same
question:

```
dcim / site / help   on /api/mcp/read-only/   →  list, retrieve
dcim / site / help   on /api/mcp/read-write/  →  list, retrieve, create, update,
                                                 partial_update, destroy,
                                                 bulk_update, bulk_partial_update,
                                                 bulk_destroy
```

Same credential, same resource, different door. The write actions are not
merely refused on the read-only door — they are **not offered**, so an agent
never plans around them.

### 3. Permission-aware discovery — same door, different resource

Now hold the door fixed. `demo-netops` on `/api/mcp/read-write/`:

```
dcim / site / help     →  list, retrieve, create, update, partial_update,
                          bulk_update, bulk_partial_update
tenancy / tenant / help →  list, retrieve
```

The door permits writes in both. The grant does not. Note also what is missing
from `dcim`: no `destroy`, no `bulk_destroy` — add and change only.

### 4. Route carving — what a door does not have

`core` and `users` are absent from `tools/list` on the scoped doors and present
on `/api/mcp/ops/`. The estate deliberately contains **no** Webhook, EventRule,
ExportTemplate, ConfigTemplate, Script or DataSource: those are the resources
the scoped routes carve out, and shipping live examples would hand anyone
reaching the admin door a working outbound request or a server-side template
render. A carve-out is demonstrated by absence, which does not require an
instance to exist.

### 5. Two shapes of refusal, and the difference is real

Try a write you are not allowed to make and read the error carefully:

| what you did | response | meaning |
|---|---|---|
| `demo-netops` creates a `tenancy/tenant` on `/api/mcp/read-write/` | **403** | the tool is on this door; **your grant** stops you |
| `demo-netops` deletes a `dcim/site` on `/api/mcp/read-write/` | **403** | same — and on a group it *can* write to |
| `demo-netops` creates a `dcim/site` on `/api/mcp/read-only/` | **404** — `Unknown tool 'site_create'` | the **ceiling** removed the tool from this door entirely |

Both are correct, and the distinction is deliberate. A 404 does not leak that
the action exists elsewhere; a 403 tells a legitimately-scoped caller that the
capability is real and their grant is the limit.

The `destroy` row is worth a second look: that action is **absent from `help`**
*and* returns 403 when attempted anyway. That is one control observed twice —
discovery declines to offer it, the dispatcher declines to run it. Only the
route ceiling yields a 404.

### 6. Writes come back lean

A successful write returns an ADR-004 lean envelope — `id`, `url`, `name`,
`status_code`, `data_size`, `continuation_token` — and deliberately does **not**
echo the fields you changed. Read the object back to see them. (This surprised
the acceptance script first time round; the check now verifies by reading back.)

### 7. Heavy responses negotiate

The eight-device list is about 15.8 kB, which crosses the heavy-response
threshold. Instead of the full payload you get a preview, a `total_size`, a
`continuation_token` and a list of modes — `summary`, `paginated`, `filtered`,
`full` — to choose from. The four-device filtered list stays under the
threshold and comes back whole. Both behaviours are visible on this estate
without constructing anything special.

---

## The estate

Two sites, a spine-and-leaf pair at each, an edge router, addressing, two
circuits between them, two tenants and a small virtualisation footprint.

| | |
|---|---|
| sites | 2 (`DC1`, `DC2`) |
| devices | 8 |
| interfaces | 32 |
| prefixes | 4 |
| VLANs | 3 |
| circuits | 2 (+ 4 terminations) |
| tenants | 2 |
| virtual machines | 2 |

It is deliberately small. The demo is about what an agent can *see* and *do*,
not about how much data there is, and every object is one more thing to keep
correct across NetBox releases. What it must do is make a filtered query return
a genuine subset — `dcim/device` filtered to `site=dc1` returns 4 of 8 — and
make a write proof land on something recognisable.

Everything in it is fiction. The site names, addresses and serial numbers are
invented and correspond to no real network.

---

## Connecting an agent

Merge a block from
[`../common/mcp-clients/netbox.mcp.json.template`](../common/mcp-clients/netbox.mcp.json.template)
into your client's config. Connect all three entries at once — the comparison
between them is the demo.

---

## Verifying it yourself

```bash
# The identity set and the estate, asserted independently of provisioning.
# Run this on a FRESHLY BOOTED stack: the acceptance script below writes, and
# this asserts the change log is empty.
docker compose cp db/assert-identities.sh db:/tmp/assert-identities.sh
docker compose exec -T db bash /tmp/assert-identities.sh

# The three doors, end to end. 36 checks.
../common/ci/acceptance-netbox.sh
```

`docker compose restart` resets the estate between them.

### One warning is expected

`manage.py check` emits **`frisian_mcp.W016`** on a default boot, and that is
accepted rather than overlooked. It warns that heavy-response continuation
entries share the default cache with OAuth authorization codes. Every demo host
in this repository accepts it, because the fix a single-compose demo could
apply — a second alias on another logical DB of the same Redis — silences the
check without delivering the isolation it is about. Real isolation needs a
second Redis instance. `config/frisian_mcp.py` carries the opt-in and the full
reasoning; the acceptance script allows this warning **by ID** and fails on any
other finding.

---

## Building the images yourself

```bash
./publish.sh          # build and verify locally, push nothing
./publish.sh --push   # publish both images to GHCR
```

Both images carry one tag and are published together. They are two halves of
one artifact: the app image and the database it expects.

---

## Binary responses are not supported, on purpose

frisian-mcp does not return binary payloads over MCP, and will not.

Binary over MCP is **not currently a subject open in the MCP Contributors
Groups** — neither the Interest Group nor a Working Group — so there is no
specification to implement against. Beyond the absence of a standard, handing a
host agent an opaque binary blob is a real hazard: the agent cannot inspect what
it is being given, and the surrounding tooling generally cannot either.

If a specification does arrive, it will need extensive testing before this
package supports it. "The spec exists" would not be sufficient grounds.

On this host the question mostly does not arise — NetBox's demo estate is rows,
not files. It matters more on document-oriented hosts, and the same answer
applies everywhere.

---

## What is deliberately not here

* **No Webhook, EventRule, Script, ExportTemplate, ConfigTemplate or
  DataSource instances.** See the walkthrough, section 4.
* **No NetBox API tokens.** The demo authenticates through frisian-mcp tokens
  only. A `users_token` row would be a second way in that bypasses the MCP
  gateway entirely to reach the REST API directly — `db/assert-identities.sh`
  asserts there are none.
* **No baked OAuth access token.** The OAuth *client* ships, because it has no
  expiry and lets you complete an authorize flow and mint your own. An access
  token is stamped at mint time, and for a published image mint time is build
  time — so a baked one ships already dead and reads as a broken demo.
* **No group-based permissions.** This roster binds permissions to users
  directly, so that everything a check needs to read lives in one place.
