# Getting started

Ten steps, in order, ending with you having watched the same credential be
offered two different tool surfaces depending on which URL it used.

Start the stack first:

```bash
cd netbox
docker compose up
```

Same entry path as the other demo hosts — no flag, no profile. Both images pull
from GHCR; nothing builds locally. Add `-d` if you would rather have the
terminal back.

First boot takes a couple of minutes, and the `netbox` container restarts itself
once while it waits for the database. That is normal. If you script the boot, do
not add `--wait` — it treats that restart as a failed start. Watch progress with
`docker compose logs -f netbox`.

---

## 1. Log in and look at the estate

Open **<http://127.0.0.1:8083/>**.

| username | password |
|---|---|
| `demo-readonly` | `frisian-demo-public-password` |
| `demo-netops` | `frisian-demo-public-password` |
| `demo-admin` | `frisian-demo-public-password` |

Log in as `demo-readonly` and click around: **Organization → Sites** has `DC1`
and `DC2`, **Devices → Devices** has eight.

Keep this tab open. Everything an agent tells you below is checkable here, and
"the agent said the write was refused" is worth a lot less than seeing for
yourself that nothing changed.

Notice while you are logged in as `demo-readonly` that NetBox itself gives you
no edit buttons. The MCP surface and the web UI are enforcing the same grants
through different front doors.

---

## 2. Point your agent at all three doors

Copy the `mcpServers` block from
[`../common/mcp-clients/netbox.mcp.json.template`](../common/mcp-clients/netbox.mcp.json.template)
into your client's configuration. Connect **all three** — the comparison
between them is the entire demo.

```
netbox-read-only    http://127.0.0.1:8083/api/mcp/read-only    demo-readonly token
netbox-read-write   http://127.0.0.1:8083/api/mcp/read-write   demo-netops token
netbox-ops          http://127.0.0.1:8083/api/mcp/ops          demo-admin token
```

Unlike the Nautobot and Paperless demos, these are three different **URLs**, not
just three different tokens. That is what makes the next few steps possible.

The admin door is `ops`, not `admin`: MCP clients strip an `admin` suffix and
silently retry the bare path, landing the caller on a different route with a
different ceiling. Do not tidy it.

---

## 3. Ask the read-only agent what it can see

> What tools do you have for this NetBox?

Ten dispatchers: `dcim`, `extras`, `ipam`, `core`, `circuits`, `vpn`,
`tenancy`, `users`, `virtualization`, `wireless` — except `core` and `users`,
which are not there.

That absence is the route carve-out. Ask the `ops` connection the same question
and both appear. Same server, same moment, different door.

Ten tools rather than 1,176 is the dispatcher pattern: the client loads ten
schemas on connection instead of eleven hundred.

---

## 4. Ask it something real

> How many devices are at DC1, and what are they?

Four: a spine, two leaves and an edge router. Cross-check in the browser tab.

Ask for all eight and something else happens — the response comes back as a
*preview* with a `continuation_token` and a menu of modes (`summary`,
`paginated`, `filtered`, `full`). The eight-device list is about 15.8 kB, over
the heavy-response threshold; the four-device filtered list is under it and
arrives whole. You have just seen response-size negotiation without setting
anything up.

---

## 5. Now ask the read-only agent to change something

> Rename site DC1 to DC1-Primary.

It will tell you it cannot. Look at *how*:

```
Unknown tool 'site_update' in group 'dcim'   (404)
```

Not "permission denied" — **unknown**. The action was never offered, so the
agent had nothing to attempt. This matters more than a refusal would: an agent
that is told a capability exists and then blocked tends to retry, rephrase and
work around. An agent that never saw the capability plans without it.

---

## 6. Switch to the read-write door and try again

Ask `netbox-read-write` (the `demo-netops` token):

> Set the description on site DC1 to "primary datacentre".

This one works. Refresh the browser tab and the description is there.

Put it back:

> Clear the description on site DC1.

Notice what the write returned: `id`, `url`, `name`, `status_code` — and *not*
the description you set. That is the lean write envelope. To see the field you
changed, read the object back.

---

## 7. Find the edge of the grant

Same agent, same door:

> Create a new tenant called "Acme".

Refused — but with a **403**, not a 404:

```
You do not have permission to use 'tenant'/'create' in group 'tenancy'
```

Compare that with step 5. The two refusals mean genuinely different things:

| code | meaning |
|---|---|
| **404** | the door's ceiling removed the tool; it is not here for anyone |
| **403** | the tool is here, and *your* grant is what stops you |

`demo-netops` has the write tier on a door that permits writes across eight
groups. It can write in two: `dcim` and `ipam`. The door was never the limit
that time — the identity was.

Then try one step finer:

> Delete site DC2.

```
You do not have permission to use 'site'/'destroy' in group 'dcim'   (403)
```

A **403** again, and on `dcim` — the group this identity *can* write to.
`demo-netops` holds add and change but not delete, so `destroy` is absent from
the `dcim` action list even though `create` and `update` are there.

Worth pausing on: `destroy` is missing from `help` **and** returns 403 when
attempted. That is one control seen twice — discovery declines to offer it, and
the dispatcher declines to run it. Only the route ceiling produces the 404 from
step 5, where the tool is not on the door at all.

Three different limits, all visible, all on one caller.

---

## 8. The step that makes the point — one token, two doors

This is the one to actually do.

Take the **admin** token — the superuser, the highest tier in the demo — and
send it at the **read-only** door. Ask what it can do to a site:

```bash
for door in read-only read-write; do
  echo "== $door"
  curl -sS -X POST \
    -H "Authorization: Bearer frisian-demo-admin-token-public-do-not-reuse" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"dcim","arguments":{"resource":"site","action":"help"}}}' \
    "http://127.0.0.1:8083/api/mcp/$door/"
done
```

```
read-only  : list, retrieve
read-write : list, retrieve, create, update, partial_update, destroy,
             bulk_update, bulk_partial_update, bulk_destroy
```

Same credential. Same resource. Same instant. The door decided.

`highest_tier` on a route is a **ceiling, not a grant** — it caps what anyone
can reach through that path and hands out nothing. The caller's own permissions
then narrow it further. Both apply, in that order, and step 7 showed the second
one working while this step shows the first.

If those two lists ever come back *identical*, the routes are mounted but the
ceiling is not being applied. On this host the plugin wrapper does the mounting,
and there is a specific way to get it wrong that produces exactly that symptom;
`common/ci/acceptance-netbox.sh` section 5 exists to catch it.

---

## 9. Look at the token accounting

Every response carries a `_usage` block:

```json
{"schema_tokens": 310, "request_tokens": 29, "result_tokens": 73,
 "total_tokens": 412, "encoding": "cl100k_base"}
```

`schema_tokens` is what the tool schema cost the model, separately from the
answer. On a 1,176-tool API this is the number the dispatcher pattern exists to
control — ask the same question through a door offering fewer actions and watch
it drop.

---

## 10. Break it and put it back

Log in as `demo-admin` in the browser and delete a device. Or have the ops agent
do it.

Then:

```bash
docker compose restart
```

`PGDATA` is a tmpfs, so the estate is restored from the baked dump on every
start — about four seconds. Your device is back.

You will also be logged out of the web UI, because sessions live in the
database. Also not a bug.

---

## Verify the whole thing yourself

```bash
# Identity set and estate, asserted independently of the provisioning code.
# Run this on a FRESHLY BOOTED stack — it asserts the change log is empty, and
# everything above wrote to it.
docker compose restart && sleep 20
docker compose cp db/assert-identities.sh db:/tmp/assert-identities.sh
docker compose exec -T db bash /tmp/assert-identities.sh

# All three doors, end to end. 36 checks.
../common/ci/acceptance-netbox.sh
```

Expect one warning from `manage.py check`: `frisian_mcp.W016`, about the
heavy-response cache sharing the default cache. It is accepted deliberately on
every demo host in this repository — `config/frisian_mcp.py` explains why the
obvious fix would silence the check without delivering the property.

---

## Where to go next

* [`README.md`](README.md) — the identities, the routes, the estate, and what
  is deliberately absent from it
* [`config/frisian_mcp.py`](config/frisian_mcp.py) — the whole configuration,
  commented at length. The routes and dispatch groups are near the top.
* [`plugin/frisian_mcp_netbox/`](plugin/frisian_mcp_netbox/) — the plugin
  wrapper, and why NetBox needs one when other Django hosts do not
* [`../common/docs/HOST-CONTRACT.md`](../common/docs/HOST-CONTRACT.md) — what
  every demo host in this repository has to provide
