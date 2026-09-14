#!/bin/sh
# Container startup: initialize state, try fresh content, then start the worker and nginx
set -eu
. /usr/local/lib/site-lib.sh

# Validate the Docker environment before copying state or contacting GitHub.
configure_polling
site_log "Polling every ${SITE_POLL_INTERVAL}–$((SITE_POLL_INTERVAL + 30)) seconds"

mkdir -p "$SITE_RELEASES"
# Seed writable Git metadata once. On container restart, reuse the existing store
# and published symlink so an outage does not discard the last downloaded site.
if [ ! -d "$SITE_REPO" ]; then
    cp -a "$SITE_FALLBACK/repository.git" "$SITE_REPO"
fi
if [ ! -L "$SITE_CURRENT" ]; then
    # Resolve to an absolute, commit-named fallback directory. The refresh script
    # reads that directory name as the successfully published commit ID.
    ln -s "$(readlink -f "$SITE_FALLBACK/current")" "$SITE_CURRENT"
fi

initial_delay=$SITE_POLL_INTERVAL
# Try current main before accepting HTTP traffic. refresh_attempt bounds the wait;
# on failure the existing symlink still points to usable content, and retries slow.
if ! refresh_attempt; then
    initial_delay=$(next_retry_delay "$SITE_POLL_INTERVAL")
    site_log "Startup refresh failed; keeping current release (baked fallback on first start), retrying in ${initial_delay}–$((initial_delay + 30)) seconds"
fi

# The worker inherits the validated polling settings and runs beside nginx.
refresh_loop "$initial_delay" &
# Preserve nginx's official initialization hooks and replace this startup shell
# with nginx. tini remains PID 1 and forwards shutdown to the worker and server.
exec /docker-entrypoint.sh "$@"
