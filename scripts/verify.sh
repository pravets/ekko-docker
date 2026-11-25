#!/usr/bin/env bash
# Verify the image really fixes $HOME permissions and ships gh, running as the
# non-root runtime uid. Requires a working docker daemon.
set -euo pipefail

IMAGE="${1:?usage: verify.sh <image>}"
UID_ARG="${RUNTIME_UID:-1000}"
GID_ARG="${RUNTIME_GID:-1000}"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

fail=0
check() {
  local name="$1"; shift
  if docker run --rm --user "${UID_ARG}:${GID_ARG}" --entrypoint /bin/bash "$IMAGE" -lc "$*" >"$OUT" 2>&1; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s\n' "$name"
    sed 's/^/       /' "$OUT"
    fail=1
  fi
}

echo "verifying $IMAGE as ${UID_ARG}:${GID_ARG}"
check 'non-root runtime'      '[ "$(id -u)" != 0 ]'
check 'uid matches build arg' '[ "$(id -u)" = '"${UID_ARG}"' ]'
check 'HOME writable'         'touch "$HOME/.permcheck" && rm -f "$HOME/.permcheck"'
check 'config creatable'      'mkdir -p "$HOME/.config/probe" && rmdir "$HOME/.config/probe"'
check 'local/bin writable'    'touch "$HOME/.local/bin/probe" && rm -f "$HOME/.local/bin/probe"'
check 'bashrc writable'       'printf "# probe\n" >> "$HOME/.bashrc"'
check 'gh present'            'gh --version'
check 'jq present'            'jq --version'
check 'fd and bat symlinks'   'fd --version && bat --version'
check 'passwd entry exists'   'getent passwd "$(id -u)"'

echo
docker run --rm --user "${UID_ARG}:${GID_ARG}" --entrypoint /bin/bash "$IMAGE" \
  -lc 'id; echo "HOME=$HOME"; ls -ld "$HOME"; gh --version | head -1'

exit "$fail"
