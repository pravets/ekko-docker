#!/bin/sh
# shellcheck shell=sh
# Entrypoint for the ekko-docker image.
#
# Normal docker/compose path ($$ == 1): hand over to s6-overlay's /init, which
# runs stage1/stage2 (UID remap via HERMES_UID, volume chown, cont-init hooks),
# starts the s6-rc bundles and then supervises everything. The Studio server is
# the `studio` service, so the container stays up as long as s6-svscan runs.
#
# Wrapped runtime (Fly, --init): the platform already owns PID 1, /init would
# abort with "can only run as pid 1", so bootstrap by hand and exec the server
# directly. Supervision is lost there; that is a platform limitation, not ours.

set -e

if [ "$$" -eq 1 ]; then
    exec /init
fi

echo "[ekko] entrypoint is not PID 1; s6-overlay skipped, running the server directly." >&2
export PATH="/command:/usr/local/bin:${PATH}"
[ -x /opt/hermes/docker/stage2-hook.sh ] && /opt/hermes/docker/stage2-hook.sh || true
exec /app/bin/start-studio-all.sh "$@"
