# ekko-docker - Ekko Studio image with sane $HOME permissions, non-root runtime, gh CLI.
#
# Rebase on a PUBLISHED Studio tag instead of building Studio from source: a source
# build runs `npm ci` + a Vite build (minutes to tens of minutes, several GB); this
# layer adds apt packages in ~1-2 minutes.
#
# Tag numbering on Docker Hub is NOT monotonic: v1.1.0 was published 2026-11-17 while
# v0.8.30 was published 2026-11-21. v1.x tags are the Android app line, not the
# server, so "bigger version" can mean older build. Always check the image `created`
# timestamp (scripts/check-base.sh) before bumping this pin.
ARG BASE_IMAGE=ekkoye8888/hermes-web-ui:v0.8.32
# The pin lives in the ARG default above; hadolint cannot see through the variable.
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

# uid/gid the container actually runs as. The upstream deployment starts the container
# with a bare numeric uid (no /etc/passwd entry) while $HOME stays root-owned - exactly
# the bug this image fixes. Read the real value first:
#   docker inspect -f '{{.Config.User}} | {{.HostConfig.User}}' <container>
ARG RUNTIME_UID=1000
ARG RUNTIME_GID=1000
ARG RUNTIME_USER=agent

# Extra Debian packages; all verified present in trixie/main.
ARG EXTRA_PACKAGES="jq yq less tree htop unzip zip rsync gnupg ripgrep fd-find bat fzf sqlite3 vim-tiny procps"

# hadolint ignore=DL3066
USER root

# --- Debian tooling ---
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ${EXTRA_PACKAGES} \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && rm -rf /var/lib/apt/lists/*

# --- GitHub CLI from the official apt repo (2.105.0 vs 2.46.0 in trixie/main) ---
# hadolint ignore=DL3008
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/* \
    && gh --version

# --- Fix $HOME ownership ---
# Upstream sets ENV HOME=/home/agent but never creates or chowns it, so the runtime
# uid cannot create ~/.config, ~/.local, ~/.bashrc, ~/.ssh.
# Only the image-layer part of $HOME is touched: /home/agent/.hermes and
# /home/agent/.hermes-web-ui are volumes mounted at runtime and keep their own
# ownership (stage2-hook chowns HERMES_HOME at boot). Never chown those recursively.
#
# No account is created here on purpose: the base image already ships `hermes`
# (uid 10000) and s6-overlay stage2 remaps it to HERMES_UID at boot. Creating a
# second account on that uid would make `usermod -u` collide and abort the boot.
# hadolint ignore=SC2016
RUN set -eux; \
    install -d -m 2775 -o "${RUNTIME_UID}" -g 0 /home/agent; \
    install -d -m 2770 -o "${RUNTIME_UID}" -g 0 \
        /home/agent/.config /home/agent/.local /home/agent/.local/bin \
        /home/agent/.cache /home/agent/.ssh; \
    install -d -m 2775 -o "${RUNTIME_UID}" -g 0 /home/agent/.hermes/bin; \
    printf 'export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"\n' > /home/agent/.bashrc; \
    chown "${RUNTIME_UID}:0" /home/agent/.bashrc; \
    chmod 0664 /home/agent/.bashrc

ENV PATH=/home/agent/.local/bin:/home/agent/.hermes/bin:${PATH}

# --- Variant B: s6 supervision, PID 1 = /init ---
# The base image ships s6-overlay 3.2.3 and the Studio entrypoint threw it away by
# exec'ing node directly. With PID 1 = node, s6 is inert and `hermes gateway
# install` dispatches to the "container" backend, refusing to install anything.
# Restoring /init gives us the supervision tree: per-profile gateway slots
# (/run/hermes-service, supervised by the image's profile-gateways service) and
# automatic restart of the Studio server.
#
# CONSEQUENCE, and it is not optional: stage2-hook.sh REJECTS a container started
# with an arbitrary `--user <uid>` (bootstrap needs root: UID remap, volume chown,
# config seeding). So this image must start as root and hand the uid in via
# HERMES_UID/HERMES_GID. Every service drops privileges with s6-setuidgid, so no
# application process runs as root.
ENV HERMES_UID=${RUNTIME_UID}
ENV HERMES_GID=${RUNTIME_GID}

COPY docker/ /app/docker/
RUN chmod +x /app/docker/entrypoint.sh \
        /app/docker/s6-rc.d/studio/run \
        /app/docker/s6-rc.d/studio/finish \
    && cp -R /app/docker/s6-rc.d/. /etc/s6-overlay/s6-rc.d/

# Bootstrap must run as root; the supervised server does not.
# DL3002 is knowingly suppressed: s6 stage2 needs root for usermod + volume chown,
# and every longrunning service drops to HERMES_UID via s6-setuidgid.
# hadolint ignore=DL3002,DL3066
USER root
ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD []
