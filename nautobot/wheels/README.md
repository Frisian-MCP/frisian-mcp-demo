# Local wheel drop for the rehearsal lane

Build a wheel from a frisian-mcp checkout and drop it here, then build with
`FRISIAN_MCP_LOCAL_WHEEL` naming the file:

    python -m pip wheel --no-deps --wheel-dir <this dir> /path/to/frisian-mcp
    docker compose -f docker-compose.yml -f docker-compose.build.yml build \
      --build-arg FRISIAN_MCP_LOCAL_WHEEL=frisian_mcp-1.1.0-py3-none-any.whl

## Why this lane exists

The hardening (H3 + H9) is on `origin/main` at version 1.1.0, but **1.1.0 is
not published to PyPI** — the newest release there is 1.0.12, on which
`FRISIAN_MCP_ROUTES` does not exist at all. So there is currently no PyPI pin
that satisfies the floor, and the local wheel is the only lane that can build
an image with the controls this demo demonstrates.

When a release containing H3 + H9 is published, `FRISIAN_MCP_SPEC` takes over
and this lane stays for local iteration.

## Wheels are never committed

`.gitignore` excludes `*.whl` here. The wheel is a build input, not a repo
artifact, and committing one would put an unreviewable binary in a public repo.
