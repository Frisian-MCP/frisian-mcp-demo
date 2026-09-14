# Frisian npm package tarballs (local lane)

This directory holds **packed `.tgz` files** for the local/rehearsal build lane.

Tarballs are **gitignored** by design — they are build inputs, not repository
artifacts, exactly like `wheels/*.whl` in Python hosts.

## How to pack tarballs

From the `frisian-mcp` monorepo (or wherever the Nest packages are built):

```bash
# Pack nestjs-test and core-test
npm pack @frisian-mcp/nestjs-test
npm pack @frisian-mcp/core-test

# Copy the resulting .tgz files here
cp frisian-mcp-nestjs-test-*.tgz /path/to/frisian-mcp-demo/teable/.frisian/
cp frisian-mcp-core-test-*.tgz /path/to/frisian-mcp-demo/teable/.frisian/
```

Or with `yarn`:

```bash
yarn pack @frisian-mcp/nestjs-test
yarn pack @frisian-mcp/core-test
# Copy as above
```

## Build lanes

### Local lane (rehearsal)

Use when testing unreleased Frisian packages:

```bash
cd teable
FRISIAN_LOCAL_TARBALLS=1 docker compose -f docker-compose.yml -f docker-compose.build.yml build
```

Requires:
- `frisian-mcp-nestjs-test-*.tgz` present in this directory
- `frisian-mcp-core-test-*.tgz` present in this directory

### npm next lane

Use when testing published `next` channel packages:

```bash
cd teable
FRISIAN_NPM_NEXT=1 docker compose -f docker-compose.yml -f docker-compose.build.yml build
```

Installs from npm registry's `next` dist-tag (no tarballs needed).

## Clean clone behavior

The Dockerfile's `COPY .frisian/` step cannot fail on a clean clone — that
would break the zero-flag rule. So this directory ships `.gitkeep` and this
README, and `*.tgz` is gitignored.

A local build without tarballs fails **loudly at RUN time** rather than at
COPY time, with a clear message about which lane to use.

## See also

- `common/docs/HOST-CONTRACT.md` Nest section
- `common/docs/PUBLISHING.md` npm lanes table
- `teable/Dockerfile` lane logic
