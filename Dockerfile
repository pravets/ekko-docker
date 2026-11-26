# ekko-docker - Ekko Studio image with sane $HOME permissions, non-root runtime, gh CLI.
#
# Rebase on a PUBLISHED Studio tag instead of building Studio from source: a source
# build runs `npm ci` + a Vite build (minutes to tens of minutes, several GB); this
# layer adds apt packages in ~1-2 minutes.
#
# Tag numbering on Docker Hub is NOT monotonic: v1.1.0 was published 2026-11-17 while
# v0.8.30 was published 2026-11-21, and `latest` pointed at v0.8.30. Check the image
# `created` timestamp (scripts/check-base.sh) before bumping this pin.
ARG BASE_IMAGE=ekkoye8888/hermes-web-ui:v0.8.30
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

# --- Fix $HOME ownership + create a real non-root account ---
# Upstream sets ENV HOME=/home/agent but never creates or chowns it, so the runtime uid
# cannot create ~/.config, ~/.local, ~/.bashrc, ~/.ssh.
# Only the image-layer part of $HOME is touched: /home/agent/.hermes and
# /home/agent/.hermes-web-ui are volumes mounted at runtime and keep their own
# ownership. Never chown those recursively.
# hadolint ignore=SC2016
RUN set -eux; \
    if ! getent group "${RUNTIME_GID}" >/dev/null; then \
        groupadd -g "${RUNTIME_GID}" "${RUNTIME_USER}"; \
    fi; \
    if ! getent passwd "${RUNTIME_UID}" >/dev/null; then \
        useradd -l -u "${RUNTIME_UID}" -g "${RUNTIME_GID}" \
                -d /home/agent -s /bin/bash -M "${RUNTIME_USER}"; \
    fi; \
    install -d -m 0755 -o "${RUNTIME_UID}" -g "${RUNTIME_GID}" /home/agent; \
    install -d -m 0700 -o "${RUNTIME_UID}" -g "${RUNTIME_GID}" \
        /home/agent/.config /home/agent/.local /home/agent/.local/bin \
        /home/agent/.cache /home/agent/.ssh; \
    printf 'export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"\n' > /home/agent/.bashrc; \
    chown "${RUNTIME_UID}:${RUNTIME_GID}" /home/agent/.bashrc

# Volume-backed tool dir: survives container recreation, unlike image layers.
RUN install -d -m 0755 -o "${RUNTIME_UID}" -g "${RUNTIME_GID}" /home/agent/.hermes/bin

ENV PATH=/home/agent/.local/bin:/home/agent/.hermes/bin:${PATH}

# Non-root by default. Upstream ends on `USER root`, so a plain `docker run` of it makes
# the data volumes root-owned - a regression worse than the original problem.
# hadolint ignore=DL3066
USER ${RUNTIME_UID}:${RUNTIME_GID}
WORKDIR /app
