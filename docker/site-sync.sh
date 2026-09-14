#!/bin/sh
# One refresh attempt: check remote main, fetch only a changed commit, validate
# its assets, then publish atomically. Return nonzero on failure for worker backoff.
set -eu
. /usr/local/lib/site-lib.sh

# Temporary paths belong only to this attempt. Cleanup removes an incomplete
# export or uncommitted symlink on failure, timeout, and normal exit alike.
staging=
next_link=$SITE_STATE/.current.$$
cleanup() {
    if [ -n "$staging" ]; then rm -rf "$staging"; fi
    rm -f "$next_link"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Ask Git for the exact branch's commit ID, without downloading website objects
# or using GitHub's REST/GraphQL APIs. --exit-code treats missing main as failure.
remote_line=$(git ls-remote --exit-code "$SITE_REMOTE" "$SITE_REF")
remote_commit=$(printf '%s\n' "$remote_line" | awk -v ref="$SITE_REF" '$2 == ref { print $1 }')
# ls-remote patterns can match ref suffixes; require the exact branch above.
if [ -z "$remote_commit" ]; then
    site_log "Remote branch missing; keeping current release"
    exit 1
fi

# The active symlink is also the publication record: its target ends in the
# commit ID of the validated site. Compare against this rather than the local Git
# ref, which may have advanced during a previous fetch whose validation failed.
previous_release=$(readlink "$SITE_CURRENT")
published_commit=${previous_release##*/}
if [ "$remote_commit" = "$published_commit" ]; then
    site_log "Already serving $published_commit; skipping fetch"
    exit 0
fi

# Fetch only main's latest snapshot, without tags or a merge into a working tree.
# The leading + permits force-pushes and rollbacks to an older remote commit.
git --git-dir="$SITE_REPO" fetch --quiet --depth=1 --no-tags \
    origin "+$SITE_REF:$SITE_REF"
# main may change between ls-remote and fetch: publish and record the fetched ID.
fetched_commit=$(git --git-dir="$SITE_REPO" rev-parse "$SITE_REF")
release=$SITE_RELEASES/$fetched_commit
# Retained releases are already validated; a rollback can reuse them directly.
if [ ! -d "$release" ]; then
    # Stage outside the active root. Failure leaves the symlink untouched, and
    # the EXIT trap discards this attempt's staging directory.
    staging=$(mktemp -d "$SITE_RELEASES/.staging.XXXXXX")
    if ! export_site "$SITE_REPO" "$fetched_commit" "$staging"; then
        site_log "Invalid website at $fetched_commit; keeping $published_commit"
        exit 1
    fi
    mv "$staging" "$release"
    # This directory now belongs to the retained release, not the EXIT trap.
    staging=
fi
ln -s "$release" "$next_link"
# Rename on the same filesystem: requests never see a partially copied release.
# -T replaces the symlink itself instead of moving a link inside its target.
# Publication and the recorded commit change together, without reloading nginx.
mv -T "$next_link" "$SITE_CURRENT"
site_log "Published $fetched_commit"

# Retain the active and immediately previous downloaded releases. The baked
# fallback lives elsewhere and is never removed. Hidden staging paths are excluded.
for old_release in "$SITE_RELEASES"/*; do
    [ -d "$old_release" ] || continue
    if [ "$old_release" != "$release" ] && [ "$old_release" != "$previous_release" ]; then
        rm -rf "$old_release"
    fi
done

# Website snapshots are independent of the object store, so obsolete Git history
# can be removed even while the previous website release is retained. This bare
# clone has no reflogs to expire separately.
if ! git --git-dir="$SITE_REPO" gc --prune=now --quiet; then
    site_log "Warning: Git cleanup failed; published release remains available"
fi
