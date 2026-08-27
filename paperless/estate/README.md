# The demo estate's media tree

`media.tar.gz` lands here and is COPYed into the application image. It is not
in git — it is a build artifact, and a multi-megabyte binary one.

## Why the application image carries half the estate

Paperless's estate is not just database rows. Every document has an original
file, a thumbnail and an archive copy on disk. A database that references files
which are not there is not a demo: listing works and every download, preview
and thumbnail 404s.

So the two published images are two halves of one artifact:

| image | carries |
|---|---|
| `demo-paperless-db` | the SQL — documents, tags, identities, tokens |
| `demo-paperless` | the files that SQL points at |

That is a second, independent reason the two must never be pulled at different
tags, on top of the usual dump-is-welded-to-its-migration-state one.

## Producing it

    cd paperless
    FRISIAN_MCP_LOCAL_WHEEL=<wheel> ./seed/seed.sh

That writes both halves: `db/demo.sql.gz` and `estate/media.tar.gz`. Never
produce one without the other.

## Building without it

The build succeeds. The image boots, shows zero documents, and
`/custom-cont-init.d/10-restore-demo-estate.sh` prints a banner saying exactly
that on every start — because "the demo has no documents in it" otherwise looks
like a bug in the seed, in the database image, or in frisian-mcp.
