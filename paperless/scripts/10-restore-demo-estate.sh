#!/command/with-contenv /bin/bash
#
# Restore the demo estate's MEDIA tree, on every container start.
#
# Paperless runs this from /custom-cont-init.d, after migrations and the search
# index and before any service starts. Two constraints come from that
# directory, and both are enforced by the Dockerfile's COPY rather than here:
# the file must be owned by root and must not be world-writable, or paperless's
# init-custom-init prints a tampering warning and skips the ENTIRE directory —
# which would leave the estate silently absent with the container otherwise
# healthy.
#
# ── WHY THE MEDIA TREE IS RESTORED AT ALL ──────────────────────────────────
#
# The database half of the estate rides in the db image and is restored by
# postgres's initdb hook. The FILES the database points at cannot ride there.
# A document row whose original is missing gives you a demo where listing works
# and every download, preview and thumbnail 404s.
#
# ── WHY IT IS RESTORED ON EVERY START, NOT JUST THE FIRST ──────────────────
#
# So the two halves stay in step. The database is restored on every start (its
# PGDATA is a tmpfs), so anything that restored media only once would drift:
# delete a document, restart, and the row is back while its file is gone.
#
# /usr/src/paperless/media is mounted as a tmpfs by docker-compose.yml for the
# same reason PGDATA is. Note that leaving the volume undeclared is NOT enough:
# the upstream image declares VOLUME on media, so Docker creates an ANONYMOUS
# volume regardless and Compose preserves it across container recreation.
#
# The practical consequence, and it is intended: changes you make to the demo
# estate do not survive a restart, and getting back to a clean estate never
# takes more than `docker compose restart`.
set -euo pipefail

log_prefix="[demo-estate]"
estate_dir="/usr/src/paperless/demo-estate"
tarball="${estate_dir}/media.tar.gz"
media_dir="${PAPERLESS_MEDIA_ROOT:-/usr/src/paperless/media}"

if [ ! -f "$tarball" ]; then
  # Loud, and deliberately not fatal.
  #
  # Not fatal because an estate-less image is a legitimate thing to build while
  # iterating on the config — and because failing here would replace a
  # comprehensible empty demo with an unexplained boot loop.
  #
  # Loud because "the demo has no documents in it" otherwise looks like a bug
  # in the seed, in the database image, or in frisian-mcp, and this is the only
  # place that knows the real answer.
  echo "${log_prefix} ============================================================"
  echo "${log_prefix} NO DEMO ESTATE IN THIS IMAGE."
  echo "${log_prefix}"
  echo "${log_prefix}   expected: ${tarball}"
  echo "${log_prefix}"
  echo "${log_prefix} Paperless will start normally and show ZERO documents."
  echo "${log_prefix} The media artifact is produced by paperless/seed/seed.sh and"
  echo "${log_prefix} injected into paperless/estate/ at build time. It is not in"
  echo "${log_prefix} git: it is a build artifact."
  echo "${log_prefix} ============================================================"
  exit 0
fi

echo "${log_prefix} restoring the demo media tree into ${media_dir}"

# Wipe first. Extracting over the top would merge the shipped estate with
# whatever a previous run left behind, which is how a demo ends up with
# documents nobody can account for.
#
# The directory itself is preserved rather than removed and recreated: it is a
# mount point, and removing it inside the container is not a thing that works.
find "$media_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

tar -xzf "$tarball" -C "$media_dir"

# The tmpfs mount arrives root-owned. Paperless runs as uid 1000, and a media
# tree it cannot read is indistinguishable from one that is not there.
chown -R paperless:paperless "$media_dir"

count=$(find "$media_dir/documents/originals" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "${log_prefix} restored ${count} original document file(s)"
