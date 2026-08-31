# Security policy

This repository ships **demonstration** systems. Read the next section before
reporting anything — it rules out the most common report, on purpose.

---

## The credentials in this repository are published deliberately

Every token, password, HMAC key and OAuth client secret in this repo and in the
published images is a **fixed, public constant**. They are printed in the
READMEs, committed in `.env`, and baked into the demo databases. That is what
removes the setup step and lets `docker compose up` work on a fresh clone with
no configuration.

They all carry the same marker:

```
frisian-demo-readonly-token-public-do-not-reuse
frisian-demo-netops-token-public-do-not-reuse
frisian-demo-admin-token-public-do-not-reuse
frisian-demo-public-client-secret-do-not-reuse
frisian-mcp-demo-public-hmac-key-do-not-reuse
frisian-demo-public-password
```

**Finding one of these is not a vulnerability, and neither is a scanner
flagging them.** Please do not report them. They protect nothing, because
everything they unlock is already public.

The controls that *are* real are the network posture and the permission model:

* Compose binds published ports to `127.0.0.1`. Widening that to `0.0.0.0`
  publishes a stack whose administrative password is in a public git
  repository. `.env.example` documents this; it is supported, and it is your
  decision, not a default.
* Django's `ALLOWED_HOSTS` is a second gate behind the loopback bind.
* `SECRET_KEY` is **not** baked into any image. Each host generates one on
  first boot and persists it to a volume, so no two deployments share a
  session-forgery key.

If you intend to keep an instance beyond a local throwaway demo, rotate every
credential first.

---

## Reporting a vulnerability

**Do not open a public issue for a security report.**

Use GitHub's private vulnerability reporting on this repository:
**Security → Report a vulnerability**. It creates a private thread visible only
to the maintainers.

Please include:

* which host (`nautobot/`, `netbox/`, `paperless/`) and the image tag
* the exact request or steps, ideally as a `curl` or a tool call
* what you expected, and what happened instead
* whether it reproduces on a fresh `docker compose up` — the estate is restored
  on every start, so "fresh" is one `docker compose restart` away

We will acknowledge the report and tell you whether it is in scope for this
repository or for the package (see below).

---

## Which repository does a report belong to?

This repository packages and configures the demo hosts. The MCP gateway itself
lives in
[Frisian-MCP/frisian-mcp](https://github.com/Frisian-MCP/frisian-mcp).

| Report | Where |
|---|---|
| A caller reaches a tool the route's `highest_tier` should have removed | **package** |
| A caller invokes an action their permissions do not grant | **package** |
| Discovery lists a tool the caller cannot use, or vice versa | **package** |
| Authentication or the OAuth flow behaves incorrectly | **package** |
| A demo image contains a credential **not** listed above as published | **here** |
| A demo host's configuration contradicts what its README claims it enforces | **here** |
| An image ships a resource the route model is documented as carving out | **here** |
| Something about how the images are built or published | **here** |

When in doubt, report it here and say so. Routing it is our job, not yours.

---

## In scope for this repository

* A **configuration** in `*/config/` that does not enforce what its host README
  and `common/ci/acceptance-*.sh` say it enforces.
* An identity in a published database holding permissions beyond those asserted
  by that host's `db/assert-identities.sh`.
* A credential in a published image that is **not** one of the documented
  public constants — for example a leftover build identity, a live API token,
  or a session.
* A published image containing an instance of a resource the scoped routes deny
  (webhooks, event rules, scripts, export/config templates, data sources). The
  demo ships none of these on purpose; one appearing would mean the two layers
  of control disagree.
* Anything about the supply chain of the published images: how they are built,
  tagged, or signed.

## Not in scope

* **The published credentials**, per the first section.
* **The demo's deliberately open posture** — three identities with documented
  authority, an anonymously-readable OAuth discovery surface, and a database
  restored to a known state on every start.
* **Running a demo host exposed to a network.** The compose files bind to
  loopback and the READMEs say why. Exposing one and reporting that strangers
  can reach it is not a finding.
* **Vulnerabilities in the upstream applications themselves** — Nautobot,
  NetBox, Paperless-ngx, PostgreSQL, Redis. Please report those to their own
  projects. If an upstream issue is made materially worse by *our* packaging,
  that part is in scope here.
* **Denial of service** against a local demo stack.

---

## Supported versions

| Version | Supported |
|---|---|
| `v0.1.0-pre` (current) | ✅ |
| anything earlier | ❌ |

There is no `latest` tag, and the application and database images for a host
must always be pulled at the **same** tag — they are two halves of one artifact.

⚠️ The `-pre` suffix is meaningful. These images carry a **pre-release**
frisian-mcp built from `main`, not a published one; PyPI's newest release is
older. The provenance is recorded on every image as
`org.frisian.demo.frisian-mcp-source` and
`org.frisian.demo.frisian-mcp-wheel-sha256`, so you can check exactly what an
image contains:

```bash
docker buildx imagetools inspect ghcr.io/frisian-mcp/demo-netbox:v0.1.0-pre \
  --format '{{json .Image}}'
```

Fixes land on the current tag. There are no backports.
