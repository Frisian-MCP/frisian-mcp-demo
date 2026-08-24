# Local wheel drop for the rehearsal lane

Drop a frisian-mcp wheel here and name the file when you build:

    docker compose -f docker-compose.yml -f docker-compose.build.yml build nautobot
    # with FRISIAN_MCP_LOCAL_WHEEL=frisian_mcp-1.1.0-py3-none-any.whl exported

## Why this lane exists

The hardening (H3 + H9) is on `origin/main` at version 1.1.0, but **1.1.0 is
not published**. PyPI's newest frisian-mcp is 1.0.12, Test PyPI's is also
1.0.12, and there is no `v1.1.0` tag. A pin resolves against an *index*, not a
git branch — so today no PyPI spec both satisfies the floor and installs, and
this is the only lane that can build an image carrying the controls this demo
demonstrates.

When a release containing H3 + H9 is published, `FRISIAN_MCP_SPEC` takes over
and this lane stays for local iteration.

## 🔴 THE SOURCE OF TRUTH IS `origin/main`, BUILT FROM A CLEAN EXPORT

Not a working checkout, and **specifically not `frisian-mcp/dist/`**.

```bash
mkdir -p /tmp/fm && git -C /path/to/frisian-mcp archive origin/main | tar -x -C /tmp/fm
python -m pip wheel --no-deps --wheel-dir <this dir> /tmp/fm
```

### Why `dist/` is a trap, measured

That directory holds several wheels and the newest one is stale:

```
dist/frisian_mcp-1.1.0-py3-none-any.whl    15 July,  246,026 bytes
  src/*.py newer than it                   21 files
  checkout branch    fix/input-validation-disclosure   ← not main, not hardening
  uncommitted in src/                      5 files modified
dist/ also contains 1.0.12 and 0.9.51 wheels
```

Same filename, same version string, **five weeks of hardening missing** — and
building from that checkout would bake another project's in-flight, uncommitted
work into a public demo image. A clean export from `origin/main` gives
**298,709 bytes**: a 52KB difference, not a subtle one.

**Do not use `git checkout` or `git stash` to get a clean tree.** That checkout
is another project's working directory and someone is routinely mid-edit in it.
`git archive` touches nothing.

### The build-time guard covers less than it looks like

`Dockerfile`'s content assertion refuses a wheel missing `_caller_rank` /
`entry_is_visible`, so a pre-hardening wheel like the 15-July one fails the
build rather than shipping. But it checks for **the H3/H9 markers, not for
freshness** — a stale wheel that happens to postdate the hardening would pass.
The guard is not a substitute for building from the stated source.

## Recording provenance

The image states its own input; this is the way to check it:

```bash
docker run --rm --entrypoint cat <image> \
  /usr/local/lib/python3.12/site-packages/frisian_mcp-1.1.0.dist-info/direct_url.json
# → {"archive_info": {"hashes": {"sha256": "…"}}, "url": "file:///tmp/wheels/…"}
```

### ⚠️ The sha256 identifies the ARTIFACT, not the source

Measured: two wheels built minutes apart from the *same* clean export of
`origin/main @ 09ab4f7` are both 298,709 bytes and have **different** sha256
digests. Wheel builds are not byte-reproducible by default.

So record the hash to answer *"which wheel went into this image"* — that is
genuinely useful. Do **not** treat it as a checksum someone else can reproduce:
two people building from the same commit will get different digests, and
reading that as a source mismatch would be wrong.

For cross-checking a build, use the two things that *are* stable:

| stable | not stable |
|---|---|
| the source commit (`origin/main @ 09ab4f7`) | the wheel sha256 |
| the wheel size (298,709 bytes) | |

## Wheels are never committed

`.gitignore` excludes `*.whl` here. A wheel is a build input, not a repo
artifact, and committing one would put an unreviewable binary in a public repo.
