# NetBox server test

Validation harness for frisian-mcp against a real NetBox instance. **Not a demo
host** — no GHCR images, no `publish.sh`, nothing published. See
`common/docs/HOST-CONTRACT.md` for what a demo host is; this is deliberately
not one, which is why it lives under `server-tests/`.

## The harness itself is NOT in this repo, on purpose

It ships with the package documentation:

```
frisian-mcp/docs/installs/Django/netbox/4.x/development/
    Dockerfile  docker-compose.yml  docker-compose.frisian-mcp.yml
    docker-entrypoint.frisian-mcp.sh  configuration.py  dev.env
    plugin_wrapper/  test_oauth_flow.py
```

Copying it here would create a second copy that drifts from the one users
actually follow, and the whole point of a server test is to exercise **what
ships**. So this directory holds only what the docs do not: a repeatable
validator, and the local deltas needed to run it on a machine that is already
hosting the demo stacks.

## Running it

```bash
# 1. Put the shipped harness where NetBox expects it. Upstream NetBox has no
#    development/ directory; the harness supplies one.
cp -r ../../frisian-mcp/docs/installs/Django/netbox/4.x/development/. \
      /path/to/netbox/development/
chmod +x /path/to/netbox/development/docker-entrypoint.frisian-mcp.sh

# 2. ONE local delta: move the published port off 8080.
#    8080 is the Nautobot demo, 8081 Paperless, 8082 Open edX.
#    Edit development/docker-compose.yml:  "8080:8080"  ->  "8083:8080"

# 3. Up
cd /path/to/netbox/development
docker compose -f docker-compose.yml -f docker-compose.frisian-mcp.yml up -d --build

# 4. Validate
/path/to/frisian-mcp-demo/server-tests/netbox/validate.sh
```

⚠️ **Stop the demo stacks first.** The Nautobot demo's `celery_beat` leaks — it
reached 6.3 GB of anonymous memory overnight while idle, 83% of a 12 GiB Docker
allocation, and it OOM-killed an unrelated standup that then failed with
`status 137` on a database wait, naming nothing useful.

```bash
cd ../nautobot  && docker compose stop
cd ../paperless && docker compose stop
```

## What the validator checks, and why each one is there

| check | why it is not obvious |
|---|---|
| auth 401 / 401 / 200 | anonymous AND a bad token must both fail. A door that refuses *no* credential but accepts *any* credential passes the first test alone |
| schema derivation | counts startup failures. **Absence of warnings is not proof** — an empty schema is silent too — so it also asserts a write action returns a real required-field error |
| description vs help | every dispatcher must advertise exactly what it offers. Run as a SCOPED principal: a superuser cannot show the gap, because both filters are no-ops for it |
| absolute URL origin | the URL a host serializer builds must carry the caller's real origin, port included |
| real write | a 201 through the dispatcher, end to end |

## Measured baseline

NetBox `v4.6.2-34-gc81bd39f7`, **Django 6.0.5**, DRF 3.17.1, MCP at `/api/mcp/`.

```
1164 tools in 10 dispatch groups
  dcim 417/46   extras 177/21   ipam 162/18   circuits 101/11
  vpn 90/10     virtualization 64/7   tenancy 54/6   users 54/6
  wireless 27/3 core 18/5
```

Django 6.0 is the notable part: the package declares `django>=5.0` with no
upper bound and classifies only 5.0–5.2, so it installs onto 6.0 without
claiming to support it. It works — that is what this test established.

## Findings this harness produced

Recorded outside the repos, per the standing rule on finding write-ups:
`MPC_development/netbox_server_test_findings.md`.

The one worth knowing before you read the code: the `url` field NetBox stamps
on **every object in every response** used to read `http://localhost/...`
regardless of the real origin, because the synthetic request built for the host
ViewSet hardcoded `SERVER_NAME`. NetBox was the worst-affected of three hosts
for exactly that reason — it is a core part of its serializer contract, not an
occasional pagination link.
