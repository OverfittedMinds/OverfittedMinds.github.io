FROM nginx:stable-alpine

# Container configuration shared by the build and runtime scripts.
ENV POLL_INTERVAL_SECONDS=300 \
    SITE_REMOTE=https://github.com/OverfittedMinds/OverfittedMinds.github.io.git \
    SITE_REF=refs/heads/main \
    SITE_STATE=/var/lib/site \
    SITE_REPO=/var/lib/site/repository.git \
    SITE_RELEASES=/var/lib/site/releases \
    SITE_CURRENT=/var/lib/site/current \
    SITE_FALLBACK=/opt/site-fallback \
    GIT_TERMINAL_PROMPT=0

RUN set -eux; \
    apk add --no-cache \
        coreutils \
        git \
        tini

COPY docker/site-lib.sh /usr/local/lib/site-lib.sh
COPY docker/site-sync.sh docker/site-start.sh /usr/local/bin/
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Download main once during the image build to create an offline fallback.
# A bare, shallow clone keeps the current commit and its files without a working tree or full history
# Source the shared export helper to validate HTML/CSS and set nginx permissions;
# name the release after its commit so startup can compare it with remote main.
RUN set -eux; \
    . /usr/local/lib/site-lib.sh; \
    chmod +x \
        /usr/local/bin/site-sync.sh \
        /usr/local/bin/site-start.sh; \
    mkdir -p "$SITE_FALLBACK/releases"; \
    timeout -k 5 30 \
        git clone \
        --bare \
        --depth=1 \
        --branch "${SITE_REF#refs/heads/}" \
        "$SITE_REMOTE" \
        "$SITE_FALLBACK/repository.git"; \
    commit="$(git \
        --git-dir="$SITE_FALLBACK/repository.git" \
        rev-parse "$SITE_REF")"; \
    export_site \
        "$SITE_FALLBACK/repository.git" \
        "$commit" \
        "$SITE_FALLBACK/releases/$commit"; \
    ln -s \
        "releases/$commit" \
        "$SITE_FALLBACK/current"

EXPOSE 80
# SIGTERM reaches both nginx and the shell worker; nginx's inherited SIGQUIT
# would not reliably stop the worker while it sleeps or waits for a fetch.
STOPSIGNAL SIGTERM

# Check availability, including fallback content during a GitHub outage.
# Allow startup's 30-second download timeout and five-second termination grace.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD wget --spider -q http://127.0.0.1/ || exit 1

# Forward shutdown to nginx and the refresh worker, and reap child processes.
ENTRYPOINT ["/sbin/tini", "-g", "--", "/usr/local/bin/site-start.sh"]
CMD ["nginx", "-g", "daemon off;"]
