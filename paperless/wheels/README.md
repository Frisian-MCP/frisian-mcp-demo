# Local wheel drop for the rehearsal lane

Drop a frisian-mcp wheel here and name the file when you build:

    FRISIAN_MCP_LOCAL_WHEEL=frisian_mcp-1.1.0-py3-none-any.whl \
      docker compose -f docker-compose.yml -f docker-compose.build.yml build

## Why this lane exists

The per-route permission model (`FRISIAN_MCP_ROUTES`) and the H3/H9 hardening
are on `origin/main` at version 1.1.0, but **1.1.0 is not published**. PyPI's
newest frisian-mcp is 1.0.12. A pin resolves against an *index*, not a git
branch — so today no PyPI spec both satisfies the floor and installs, and this
is the only lane that can build an image carrying the controls this demo
demonstrates.

When a release containing them is published, `FRISIAN_MCP_SPEC` takes over and
this lane stays for local iteration.

## 🔴 THE SOURCE OF TRUTH IS `origin/main`, BUILT FROM A CLEAN EXPORT

Not a working checkout, and **specifically not `frisian-mcp/dist/`**. That
directory holds several wheels, the newest is stale, and the checkout it was
built from is another project's working directory with uncommitted changes in
`src/`. Same filename, same version string, weeks of hardening missing.

```bash
mkdir -p /tmp/fm && git -C /path/to/frisian-mcp archive origin/main | tar -x -C /tmp/fm
python -m pip wheel --no-deps --wheel-dir <this dir> /tmp/fm
```

**Do not use `git checkout` or `git stash` to get a clean tree.** Someone is
routinely mid-edit in that checkout. `git archive` touches nothing.

### The build-time guard covers less than it looks like

`Dockerfile` refuses a wheel missing `_caller_rank` / `entry_is_visible` /
`FRISIAN_MCP_ROUTES`, so a pre-hardening wheel fails the build rather than
shipping. But it checks for **those markers, not for freshness** — a stale
wheel that happens to postdate the hardening would pass. The guard is not a
substitute for building from the stated source.

### ⚠️ The wheel sha256 identifies the ARTIFACT, not the source

Wheel builds are not byte-reproducible by default: two wheels built minutes
apart from the *same* clean export have the same size and **different** sha256
digests. Record the hash to answer *"which wheel went into this image"*. Do not
treat it as a checksum someone else can reproduce.

| stable | not stable |
|---|---|
| the source commit | the wheel sha256 |
| the wheel size | |

## Wheels are never committed

`.gitignore` excludes `*.whl` here. A wheel is a build input, not a repo
artifact, and committing one would put an unreviewable binary in a public repo.
