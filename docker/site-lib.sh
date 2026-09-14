#!/bin/sh
# Shared helpers, sourced by startup and each one-shot refresh.
# Configuration comes from the Dockerfile's ENV declarations.

site_log() {
    # Log with UTC timestamps and a common prefix
    printf '%s [site] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

configure_polling() {
    interval_input=${POLL_INTERVAL_SECONDS-}
    case "$interval_input" in
        ''|*[!0-9]*)
            site_log 'POLL_INTERVAL_SECONDS must be a whole number between 1 and 2147483647' >&2
            return 1
            ;;
    esac
    if [ "${#interval_input}" -gt 10 ] ||
        [ "$interval_input" -eq 0 ] || [ "$interval_input" -gt 2147483647 ]; then
        site_log 'POLL_INTERVAL_SECONDS must be a whole number between 1 and 2147483647' >&2
        return 1
    fi
    # Normalize leading zeroes before using shell arithmetic.
    SITE_POLL_INTERVAL=$(expr "$interval_input" + 0)
    # Backoff must never shorten a user-selected interval longer than one hour.
    SITE_MAX_BACKOFF=3600
    if [ "$SITE_POLL_INTERVAL" -gt "$SITE_MAX_BACKOFF" ]; then
        SITE_MAX_BACKOFF=$SITE_POLL_INTERVAL
    fi
}

next_retry_delay() {
    # Return the doubled retry delay, capped at max(one hour, configured interval).
    retry_delay=$(( $1 * 2 ))
    if [ "$retry_delay" -gt "$SITE_MAX_BACKOFF" ]; then
        retry_delay=$SITE_MAX_BACKOFF
    fi
    printf '%s\n' "$retry_delay"
}

export_site() {
    # Arguments: bare repository directory, commit ID, destination directory.
    # The destination is an unpublished staging directory or the build fallback.
    export_repo=$1
    export_commit=$2
    export_destination=$3

    # Only public site assets are exported; Git and deployment files stay private.
    # Export exactly one commit so HTML and CSS come from the same revision.
    # Require nonempty regular files and reject symlinks before publication.
    # Check archive creation separately from extraction so a failed Git command
    # cannot be hidden by tar succeeding at the end of a pipeline.
    mkdir -p "$export_destination" &&
        git --git-dir="$export_repo" archive "$export_commit" -- \
            index.html dil-site.css > "$export_destination/.site.tar" &&
        tar -xf "$export_destination/.site.tar" -C "$export_destination" &&
        rm "$export_destination/.site.tar" || return 1

    for asset_path in "$export_destination/index.html" "$export_destination/dil-site.css"; do
        test -f "$asset_path" && test -s "$asset_path" && test ! -L "$asset_path" || return 1
    done
    # mktemp creates a private directory; nginx must be able to read the release.
    chmod 755 "$export_destination" &&
        chmod 644 "$export_destination/index.html" "$export_destination/dil-site.css"
}

refresh_attempt() {
    # GNU timeout bounds the entire attempt and signals its whole process group,
    # including Git's HTTPS helper. Forward shutdown into that separate group too.
    timeout --kill-after=5 30 /usr/local/bin/site-sync.sh &
    refresh_pid=$!
    # The negative PID addresses timeout's process group. Fall back to its PID if
    # shutdown arrives before the group exists. Exit instead of retrying shutdown.
    trap 'kill -TERM "-$refresh_pid" 2>/dev/null || kill -TERM "$refresh_pid" 2>/dev/null || true; exit 143' HUP INT TERM
    # Capture failure without triggering errexit, then restore normal traps.
    refresh_result=0
    wait "$refresh_pid" || refresh_result=$?
    trap - HUP INT TERM
    return "$refresh_result"
}

poll_delay() {
    # Jitter avoids synchronized requests when several containers start together.
    jitter=$(od -An -N2 -tu2 /dev/urandom)
    printf '%s\n' "$(( $1 + jitter % 31 ))"
}

refresh_loop() {
    # Argument: the first delay, already increased if the startup refresh failed.
    delay=$1
    while :; do
        # Wait after each completed attempt; checks never overlap or retry in a
        # tight loop. Even an unchanged remote hash is a successful check.
        sleep "$(poll_delay "$delay")"
        if refresh_attempt; then
            # Recovery returns to the user's base interval, rather than 300.
            delay=$SITE_POLL_INTERVAL
        else
            delay=$(next_retry_delay "$delay")
            site_log "Refresh failed; keeping current release, retrying in ${delay}–$((delay + 30)) seconds"
        fi
    done
}
