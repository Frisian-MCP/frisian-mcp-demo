# The per-host contract

This repo ships one directory per demo host. `nautobot/` is the first; others
follow the same shape. This document is what "the same shape" means, so a new
host slots in without anyone redesigning the repo.

If you are adding a host, the checklist at the bottom is the short version.

---

## The one rule everything else serves

**A host directory is self-contained.**

```
cd <host> && docker compose up
```

That must work on a fresh clone, with no flags, no `-f` chain, no `.env` to
copy first, and nothing to run at the repo root. If a change to a host
directory makes a root-level step necessary, the change is wrong.

This is the rule that keeps the demos demoable. Everything below exists to
make it hold as hosts are added.

---

## Required files

Every host directory provides exactly these names. The names are fixed — the
CI workflows, the docs and the quickstart all address them by path.

| Path | Purpose | Committed? |
|---|---|---|
| `<host>/README.md` | Host quickstart, what the demo contains, first-boot wait, safety banner | yes |
| `<host>/docker-compose.yml` | **Default path.** Pulls prebuilt images from GHCR | yes |
| `<host>/docker-compose.build.yml` | Override for building both images locally | yes |
| `<host>/.env` | Published demo values. **Committed on purpose** — see below | yes |
| `<host>/.env.example` | Annotated reference for every setting, including ones `.env` omits | yes |
| `<host>/Dockerfile` | Application image. `FROM` a published upstream image | yes |
| `<host>/config/` | Configuration files copied into the application image | yes |
| `<host>/db/Dockerfile` | Pre-seeded database image | yes |
| `<host>/db/demo.sql.gz` | The golden dump | **no — injected by CI** |

### Why `.env` is committed

A fresh clone has no `.env`, and Compose treats `env_file:` as mandatory — a
missing file aborts the whole stack before anything starts. So either `.env`
is committed or the zero-flag rule dies.

It is committed, and additionally **no host may use `env_file:`**. Container
environment is declared inline with `${VAR:-default}` defaults, so the stack
boots with `.env`, boots without it, and `.env` still overrides everything.
Two independent layers; neither alone is sufficient.

Nothing in `.env` is a secret. The images ship the same credentials by design.
`.gitignore` documents this at the top so nobody "fixes" it later.

---

## Naming conventions

### Images — two per host, one tag

```
ghcr.io/frisian-mcp/demo-<host>:<tag>
ghcr.io/frisian-mcp/demo-<host>-db:<tag>
```

**Both resolve from a single `DEMO_TAG` variable.** This is the most important
convention in the repo and the easiest one to break with a well-meaning edit.

A database dump is welded to the migration state that produced it. An
application image and a database image from different builds produce migration
errors, or worse a quietly wrong estate. Giving the two images independent
version variables makes that state reachable by a typo. Do not do it, however
reasonable it looks in isolation.

The two images are built together, tagged together, and published together.
There is no supported combination in which their tags differ.

### Compose service names

Fixed across hosts, so docs, smoke tests and troubleshooting transfer:

| Service | Role |
|---|---|
| `<app>` | The application. Named for the host (`nautobot`, `paperless`, …) |
| `db` | The pre-seeded database. Always `db`, never the engine name |
| `redis` | Cache / broker, where the host needs one |

Anything beyond these is host-specific and named for what it does
(`celery_worker`, `celery_beat`).

### Compose project name

Each host sets `name:` at the top of its compose file:

```yaml
name: frisian-mcp-demo-<host>
```

Without it, Compose derives the project name from the directory (`nautobot`),
which collides with unrelated stacks on a developer's machine and makes
`docker compose down -v` ambiguous in the worst possible way.

---

## Environment variables

### Shared — same name and meaning in every host

| Variable | Meaning |
|---|---|
| `DEMO_TAG` | The single tag driving both images |
| `DEMO_BIND_HOST` | Host interface for published ports. **Defaults to `127.0.0.1`** |
| `DEMO_HTTP_PORT` | Host port for the application's HTTP endpoint |

`DEMO_BIND_HOST` defaults to loopback in every host, without exception. These
images ship publicly known credentials; a README banner is not a control.
Binding to `0.0.0.0` is a deliberate act by the user, never a default.

### Per-host

Everything else. Use the upstream application's own variable names rather than
inventing a `DEMO_`-prefixed alias — `NAUTOBOT_DB_HOST`, not `DEMO_DB_HOST`.
Users troubleshooting reach for upstream documentation, and aliases make that
documentation wrong.

---

## `common/` versus per-host

`common/` holds only what is genuinely host-independent.

| Location | Contents |
|---|---|
| `common/docs/` | This contract, and cross-host guides |
| `common/mcp-clients/` | MCP client configuration snippets and smoke tests |
| `<host>/` | Everything else |

**Bias hard toward duplication.** Two hosts with similar compose files are
fine; a shared fragment they both `include:` is not, because it reintroduces
the repo-root coupling the self-containment rule exists to prevent, and it
makes every host a stakeholder in every edit. Duplication is cheap here and
the coupling is not.

---

## The database image

Deliberately trivial:

```dockerfile
FROM postgres:<pinned>
COPY demo.sql.gz /docker-entrypoint-initdb.d/
```

**Bake SQL text. Never a pre-initialised `PGDATA`.** A data directory is
architecture-sensitive, which would drag the entire seed pipeline through QEMU
for the multi-arch build. SQL text is architecture-independent, so the split is
clean: seed once natively, then the multi-arch bake is a file copy.

This is not an optimisation waiting to happen. It is the reason the C-track is
cheap, and "optimising" it into a baked data directory undoes that.

Two constraints on the pinned major:

- **≥ the `pg_dump` that produced the dump.** A newer `pg_dump` emits GUCs an
  older server rejects in the dump preamble, and the restore fails or, without
  `ON_ERROR_STOP`, half-succeeds.
- **Within the range the application version supports.**

If those two ranges do not overlap, the dump has to be re-cut with a matching
client — not worked around in the image.

### Known gap: the database volume defeats the lockstep guarantee

`/docker-entrypoint-initdb.d/` scripts run **only when `PGDATA` is empty**. A
host that persists the database in a named volume therefore will not restore a
newer dump on upgrade: the user pulls a new `DEMO_TAG`, gets the new
application image, and keeps the old database. The tag moved and the data did
not — exactly the mixed state the single-variable pin exists to prevent.

**This is unresolved.** It is tracked in the build room; do not assume the
current behaviour in a new host is the settled answer.

---

## No host source code. Ever.

Dockerfiles and configuration files only. Build `FROM` a published upstream
image; never vendor a source checkout, and never port an upstream project's
development harness. Those harnesses exist to protect an editable install and
carry assumptions that are actively wrong off a released base image.

Read them for **config content and pinned versions**. Do not use them as a
template.

If something appears to require vendored source, raise it rather than
vendoring it. That requirement is usually a sign the base image is wrong.

---

## Adding a new host — checklist

1. `mkdir <host>/{config,db}`
2. `Dockerfile` — `FROM` the published upstream image, install what the demo
   needs, `COPY config/`. No source checkout.
3. `config/` — locked posture. Authentication required; nothing visible
   unauthenticated. Open-world demo postures do not ship.
4. `db/Dockerfile` — `FROM postgres:<pinned>` + `COPY demo.sql.gz`.
5. `docker-compose.yml` — services named per the table above; both images from
   `${DEMO_TAG}`; ports bound to `${DEMO_BIND_HOST:-127.0.0.1}`; no
   `env_file:`; real healthcheck-based `depends_on`, never a sleep.
6. `docker-compose.build.yml` — build inputs only. It must not restate ports,
   volumes or environment.
7. `.env` + `.env.example`.
8. `README.md` — safety banner, quickstart, observed first-boot restore time.
9. `.github/workflows/build-<host>.yml` — seed once natively, then bake
   multi-arch.
10. Verify the rule: fresh clone, `cd <host>`, `docker compose up`, no flags.

Step 10 is the acceptance test. The other nine are how you pass it.
