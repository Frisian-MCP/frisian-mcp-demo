# Publishing runbook — GHCR

How the demo images get published, verified, and pruned. Applies to every
host; `nautobot` is the worked example.

**Nobody but Jeremy pushes or publishes.** Agents prepare the workflow and this
runbook and hand off the trigger.

---

## The correctness property

The application image and the database image are **two halves of one
artifact**. A dump is welded to the migration state that produced it, so an
app image and a db image from different builds produce migration errors on
boot, or a quietly wrong estate.

Everything below serves one rule:

> **Both images publish under the same tag, from the same workflow run, or
> neither publishes.**

The workflow enforces this structurally: both pushes are in a single job (a
failure between two jobs would leave one image published at a tag the other
never reaches), runs are serialised per tag, and after pushing it inspects
both manifests and fails unless both resolve on both architectures at that
tag.

---

## Three lanes, and only one of them ships

Where `frisian-mcp` comes from is a separate axis from which tag gets built.
The workflow's `lane` input carries it, and it defaults to `rehearsal` — the
most constrained lane that can still publish, and only ever under a `-pre` /
`-rc` tag — so a missing or unrecognised value never falls through to
`release`, which publishes under a plain tag and makes a promise about the
package.

| lane | source | validates | may publish |
|---|---|---|---|
| `rehearsal` | local wheel from a clean `origin/main` export | today's work | **yes — pre-release tag only** |
| `testpypi` | Test PyPI | the packaged **artifact** | **no** |
| `release` | real PyPI | what users get | **yes** |

### Why `rehearsal` may publish, when it originally could not

The first version of this rule refused every lane but `release`, on the
reasoning that a locally built wheel is unreproducible. That was correct when
it was written and stopped being true: the local lane now builds from a clean
`origin/main` export with the wheel's sha256 recorded on the image, and the
Dockerfile refuses any wheel missing the H3/H9 markers.

**Reproducibility is what made the rule right, so reproducibility is what
lifted it** — not convenience, and not the fact that the release was late.

The condition is that the tag must say what it is. A rehearsal publish goes out
under a **pre-release tag** (`-pre` / `-rc`), and the gate refuses a rehearsal
build under a plain tag and a release build under a pre-release one. An image
carrying a frisian-mcp nobody can `pip install` must not wear a tag that
invites the next person to treat it as a release.

`testpypi` still cannot publish, and that one is not a discipline call: the
index is non-durable, so a published image would outlive the artifact it was
built from.

### Why the middle lane exists

It tests the one thing a local source build cannot: that the built wheel
contains what we think it does. This package has already shipped a wheel whose
`[usage]` extra was present in the tree and **absent from the published
metadata**, so `pip install frisian-mcp[usage]` warned and silently installed
the base package. An editable install from source can never catch that.

### Why it must not ship

Test PyPI is explicitly non-durable — files can be deleted and it prunes. A
public image whose build resolved from it breaks silently later, and its
provenance is weak. Fine for validating our own work; not fine underneath
someone else's `docker pull`, where the image outlives the index it came from.

### The index is not part of the requirement specifier

Test PyPI needs `--index-url` plus real PyPI as an extra index, because it does
not carry Django, DRF or jsonschema. Those flags are passed as **separate build
args**, and `FRISIAN_MCP_SPEC` stays a bare version pin in every lane.

That split is deliberate. The publish gate rejects any spec carrying index
flags, and that rejection is what keeps an arbitrary package index out of a
published image. Folding the flags into the spec to make Test PyPI work would
mean widening the one check standing between GHCR and a wheel from anywhere.
Do not do it.

The index is **derived from the lane** in `resolve`, not supplied by the
operator: only `testpypi` gets one, every other lane gets the empty string,
and `testpypi` cannot publish. The `release` branch of the publish gate then
refuses independently if an override is set at all.

That second check is redundant while the derivation holds, which is the point
— it is the one that survives someone later making the index an input. Note
what it does **not** cover: the rehearsal lane has no index check, and does
not need one only because the derivation above leaves it empty. If an index
input is ever added, that gap opens with it.

### The lane must actually be wired

Docker ignores a build-arg the Dockerfile does not declare, and only warns. A
`testpypi` build against a Dockerfile without `ARG PIP_INDEX_URL` would install
from real PyPI and report success — a pre-release lane validating the wrong
artifact, which is worse than having no lane at all. The workflow greps for the
`ARG` declarations and fails closed if they are missing.

---

## Tagging

### Canonical tag: demo-repo semver, immutable

```
ghcr.io/frisian-mcp/demo-<host>:v0.1.0
ghcr.io/frisian-mcp/demo-<host>-db:v0.1.0
```

The version belongs to **this repo's demo build**, not to any component
inside it. A published tag is never overwritten. Re-cut a new one.

### Why component versions are not in the tag

A scheme like `1.1.0-nautobot3.2.3` reads well and breaks on the first re-cut.
Fix a provisioning bug, or re-dump after a data correction, and neither
component version changed — so there is no new tag to publish under, and the
only options are overwriting a published tag (forbidden) or inventing a suffix
the scheme did not plan for.

Component versions go in **OCI labels** instead, where they are queryable and
cannot collide:

```dockerfile
LABEL org.opencontainers.image.source="https://github.com/Frisian-MCP/frisian-mcp-demo"
LABEL org.opencontainers.image.version="v0.1.0"
LABEL org.frisian.demo.host="nautobot"
LABEL org.frisian.demo.app-version="3.2.3"
LABEL org.frisian.demo.frisian-mcp-version="1.1.0"
```

Read back with `docker buildx imagetools inspect <image>:<tag>`.

### No `latest`

**Recommendation: do not publish a `latest` tag for these images.**

`latest` is a moving pointer, and these images must be pulled as a matched
pair. Two ways that breaks in ordinary use:

1. A user pulled `latest` last month and has the db image cached. They pull
   again today; Docker fetches the new app image and reuses the cached db.
   Mismatched pair, no warning.
2. The database volume gap (see the host contract): even a correct pair does
   not re-seed over an existing volume, so the new app runs against the old
   data.

`latest` makes both failures the *default* experience rather than an edge
case. An immutable version tag makes the pair explicit, and the README names
the current one.

If a moving pointer is wanted later, it should move only after a
verification-from-clean pass, and the reasoning above should be revisited
rather than assumed stale.

---

## Publishing: one command

`nautobot/publish.sh` is the whole flow. It defaults to a dry run, so the
rehearsal is the same code path as the real thing.

```bash
cd nautobot
./publish.sh            # build both images multi-arch, verify, push NOTHING
./publish.sh --push     # the real one
```

It derives the lane, the build args, the tag suffix and the provenance labels
from a **single line** at the top of the file:

```bash
FRISIAN_MCP_SOURCE="local-wheel:frisian_mcp-1.1.0-py3-none-any.whl"
```

When a frisian-mcp release carrying the H3/H9 hardening exists, that one line
becomes:

```bash
FRISIAN_MCP_SOURCE="pypi:frisian-mcp[usage]==1.1.0"
```

and the lane flips to `release`, the `-pre` suffix disappears from the tag, and
the labels change with it. **Nothing else needs editing** — not the workflow,
not the compose files, not this document. That is deliberate: a version
placeholder that requires touching five files is one somebody eventually gets
half-right.

Both images are built and pushed back to back in the same run. They are two
halves of one artifact, so a partial publish is exactly the mixed state the
lockstep tag exists to prevent.

---

## First publish — visibility and write are TWO controls

**GHCR package visibility is NOT inherited from repository visibility**, and
the app and db images are **two separate packages** with independent settings.
Flipping or checking one says nothing about the other.

### The demo packages stay PRIVATE

Ruled by Jeremy, 2026-08-24:

> *"In GHCR it needs to be read-only for everyone and only writeable for
> approved people, so people are not pushing garbage into our registry. For
> now it should be closed until we have done our own testing."*

**This section used to say to flip both packages public at first publish.**
That guidance is superseded, not merely out of date — following it now
publishes an untested demo. A private package is also the default a push
produces, so the correct first-publish action is to *confirm* private rather
than to change anything.

### Visibility does not restrict writing, and never did

This is the conflation worth not repeating. A **public** GHCR package is
already read-only to the world — there is no anonymous push. So *"read-only
for everyone"* comes free with visibility and always did.

*"Writeable only by approved people"* is a **separate control**, unaffected by
visibility, and it is the one that actually needs configuring. Staying private
closes **reads**. It does not touch the garbage-push risk at all.

### Every write path, and what closes it

Enumerate them. A single-door assumption is how this repo's other gaps
happened.

| # | write path | closed by | auditable from here? |
|---|---|---|---|
| 1 | explicit package role assignments (read/write/admin) | grant deliberately, per person or team | **no** — no enumerating API for container packages; UI only |
| 2 | **inherited repository access** — repo write becoming package write | turn inheritance off; grant explicitly instead | yes, via the package's `repository` field |
| 3 | workflow `GITHUB_TOKEN` with `packages: write` | scoped by who can trigger the workflow | yes — read the workflow |
| 4 | PATs carrying `write:packages` | per-person hygiene | **no** — auditable only per account |

Paths 1 and 4 have no API that lists them. Record what you **see** in the UI,
not what the default ought to be.

### Measured on the nautobot pair, 2026-08-25

```
gh api '/orgs/Frisian-MCP/packages?package_type=container'
  demo-nautobot      visibility=private
  demo-nautobot-db   visibility=private

anonymous pull token: GET https://ghcr.io/token?scope=repository:<pkg>:pull
  frisian-mcp/demo-nautobot        401   refused — exists, private
  frisian-mcp/demo-nautobot-db     401   refused — exists, private
  homebrew/core/git                200   control — a public package still works
  frisian-mcp/no-such-package-xyz  403   control — a wrong name looks different

gh api '/orgs/Frisian-MCP/packages/container/demo-nautobot'     → repository: null
gh api '/orgs/Frisian-MCP/packages/container/demo-nautobot-db'  → repository: null
```

Both controls are load-bearing. The API call and the token call are also
independent of each other: the first reports the *setting*, the second reports
what a stranger actually experiences, and only the second would catch a
setting that reads Private while behaving otherwise.

### ⚠️ The repository link, and why path 2 and path 3 are one action

Neither package is linked to `frisian-mcp-demo`, **despite both carrying
`org.opencontainers.image.source`**. The OCI label does not create the GHCR
link: a CLI `docker push` does not link, a workflow push does.

So inheritance is currently **shut** — but by accident of how the first
publish was run, not by configuration, and not durably.

The consequence is the part to carry: **`packages: write` in the `publish` job
cannot reach these packages until that link exists.** Making CI publishing
work therefore *creates* the inheritance path in the same motion. They are one
action, not two. Whoever eventually fixes "CI cannot push" also hands package
write to every collaborator with repo write, unless they turn inheritance off
in the same step.

Do not read "CI cannot currently push" as a security control. It is an
unconfigured state that the first person to need CI will remove.

### At first publish, then, once per package

1. https://github.com/orgs/Frisian-MCP/packages
2. Open `demo-<host>` → **Package settings**
3. **Confirm visibility reads Private.** Do not flip it.
4. **Manage access** — restrict write to approved people. This is the standing
   policy, and it survives any later flip to public.
5. Repeat for `demo-<host>-db`, and confirm it independently. Missing the db
   package produces a demo that pulls the app and then fails on the database
   with a confusing permissions error.

### When they do go public later

Only after Jeremy says our own testing is done. Flipping visibility does
**not** restrict writes and does not need to — path 1, 2 and 4 above are
exactly as open or closed as they were the day before. Re-verify write access
after the flip anyway, because that is the moment a mistake becomes reachable
by strangers.

Both packages, every host. Then verify from clean, below.

---

## Verify from clean — do not trust the push log

A green push proves bytes were accepted. It does not prove anyone can pull
them, that the manifest advertises both architectures, or that the demo works.

On a machine with **no local cache** for these images:

```bash
# 1. Prove the local cache is not answering
docker image rm ghcr.io/frisian-mcp/demo-<host>:<tag> \
                ghcr.io/frisian-mcp/demo-<host>-db:<tag> 2>/dev/null || true

# 2. Anonymous pull — exactly like a stranger.
#
#    ⚠️ WHILE THE PACKAGES ARE PRIVATE THIS CHECK IS INVERTED:
#    both pulls MUST FAIL. A private package a stranger CAN pull is the
#    failure the policy exists to prevent, and it is invisible from an
#    authenticated machine. Once public, both must SUCCEED.
docker logout ghcr.io
docker pull ghcr.io/frisian-mcp/demo-<host>:<tag>
docker pull ghcr.io/frisian-mcp/demo-<host>-db:<tag>

#    Same verdict without touching your credential store: ask GHCR for an
#    ANONYMOUS PULL TOKEN. It answers three ways, which is the reason to
#    prefer it -- see the trap below.
#
#        200  public          -- a token was issued
#        401  exists, PRIVATE -- refused outright   (expected today)
#        403  NO SUCH PACKAGE -- you are checking a name that isn't there
#
for pkg in frisian-mcp/demo-<host> frisian-mcp/demo-<host>-db homebrew/core/git; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    "https://ghcr.io/token?scope=repository:${pkg}:pull&service=ghcr.io")
  echo "${pkg}  token-endpoint HTTP ${code}"
done
#
#    Keep the public control in the loop. Without it, a 401 on every line
#    could equally mean "correctly private" or "the whole check is broken",
#    and those are indistinguishable from the output alone.
#
#    Measured 2026-08-25:
#        frisian-mcp/demo-nautobot        401
#        frisian-mcp/demo-nautobot-db     401
#        homebrew/core/git                200   <- control
#        frisian-mcp/no-such-package-xyz  403   <- the trap, below
#
#    ⚠️ THE TRAP. The obvious alternative -- request the MANIFEST with no
#    bearer and expect a refusal -- returns 403 for a private package AND 403
#    for a package that does not exist. A typo in the package name therefore
#    reads as a pass, and you would have "verified" nothing at all. The
#    refusal to ISSUE A TOKEN is the check; the manifest failure is only its
#    downstream symptom, and it discards the distinction that matters.

# 2b. Then pull as an APPROVED account and confirm both succeed. Neither half
#     substitutes for the other: step 2 proves strangers are shut out, this
#     proves the people who should have access actually do.

# 3. Both architectures really are in the manifest list
docker buildx imagetools inspect ghcr.io/frisian-mcp/demo-<host>:<tag>
docker buildx imagetools inspect ghcr.io/frisian-mcp/demo-<host>-db:<tag>
#    Expect BOTH linux/amd64 and linux/arm64 on BOTH images.

# 4. On Apple Silicon: confirm the arm64 image, not an emulated amd64 one
docker image inspect ghcr.io/frisian-mcp/demo-<host>:<tag> \
  --format '{{.Architecture}}'      # expect: arm64

# 5. The actual user path, from a fresh clone
git clone https://github.com/Frisian-MCP/frisian-mcp-demo /tmp/demo-verify
cd /tmp/demo-verify/<host> && docker compose up
```

Step 2 is the one people skip. Publishing from an account that can already
pull private packages hides a visibility mistake completely — the push
succeeded and *you* can pull, so everything looks fine. Log out.

Note which direction you are checking. The same command is a pass at 403 and a
pass at 200 depending on the ruling in force, so "the pull behaved as I
expected" is not a result unless you wrote down which outcome you expected
first.

Step 5 is the acceptance test. The others explain a failure; this one decides
whether the demo works.

---

## Retention

These images are large. Two things accumulate.

### ⚠️ Do not naively prune "untagged" versions

This is the trap, and it corrupts **published** images.

A multi-arch push creates one tagged manifest **index** plus one
platform-specific manifest per architecture. **Those per-arch children are
reported by the GHCR API as untagged versions.** A retention job configured
with the obvious "delete all untagged versions" setting will happily delete
the children of a tagged, in-use multi-arch image.

The symptom is not a missing tag. The tag still resolves, the index is still
there, and the pull fails part-way through with a manifest-unknown error for
one architecture — typically the one nobody on the team uses, so it surfaces
as a user report weeks later.

If untagged pruning is used at all, it must be a tool that resolves index
references and excludes children of retained tags. Verify it against a test
package before pointing it at real ones.

### Recommended policy

- **Tagged versions: keep.** They are immutable releases and the whole point
  is that an old demo tag still works. Prune by hand, deliberately, when a tag
  is genuinely retired.
- **Untagged versions: leave alone by default**, until a multi-arch-aware
  pruner is in place and tested.
- Revisit when storage actually becomes a problem. Growth here is slow and
  predictable; a corrupted published image is neither.

**Open:** no retention automation is configured. That is a deliberate hold,
not an oversight.

---

## Rollback

Published tags are immutable, so rollback is "tell people the older tag":

1. Update the README's named current tag to the last good one.
2. If a bad tag is actively harmful (leaked credentials, broken migration),
   delete **both** packages' versions for that tag together. Deleting one half
   leaves the other pullable and reachable by anyone with the tag written
   down.
3. Publish the fix under a **new** tag. Never re-cut under the old one.

---

## Checklist

- [ ] Workflow triggered by Jeremy with the intended `DEMO_TAG`
- [ ] Both images pushed in the same run, same tag
- [ ] Manifest check in the workflow passed for both images, both arches
- [ ] **Both** packages confirmed **Private** — checked individually, not inferred
      from the repo or from each other (see the ruling above; do NOT flip public)
- [ ] Write restricted to approved people, all four paths walked — and the
      package `repository` field checked, because CI publishing and inherited
      repo access arrive together
- [ ] Anonymous pull verified to **FAIL** on both packages while private
- [ ] Approved-account pull verified to succeed on both
- [ ] Verified from clean on both an amd64 and an arm64 machine
- [ ] Fresh-clone `docker compose up` reaches a working demo
- [ ] README names the new tag
