#!/usr/bin/env bash
# Verify the image: $HOME permissions, gh, and the s6 supervision tree.
#
# Variant B changed the runtime contract: the container starts as ROOT
# (/init needs it for UID remap + volume chown) and every service drops to
# HERMES_UID with s6-setuidgid. So this script passes HERMES_UID instead of
# `--user`, and checks the *studio process* is non-root rather than the shell.
#
#   ./scripts/verify.sh <image>          # full: boot container, check, stop
#   ./scripts/verify.sh <image> --quick  # image-layer checks only
set -euo pipefail

IMAGE="${1:?usage: verify.sh <image> [--quick]}"
MODE="${2:-full}"
UID_ARG="${RUNTIME_UID:-1000}"
GID_ARG="${RUNTIME_GID:-1000}"
# Studio's own default is 8648; the deployed compose sets PORT=6060. Pass it
# explicitly so the check matches the deployment instead of guessing.
PORT_ARG="${PORT:-6060}"
NAME="ekko-verify-$$"
fail=0

pass() { printf '  ok   %s\n' "$1"; }
note() { printf '  note %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

in_container() { docker exec "$NAME" /usr/bin/env HOME=/home/agent sh -c "$1"; }
as_hermes()    { docker exec "$NAME" /command/s6-setuidgid hermes sh -c "$1"; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== image-layer checks =="
id_out=$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'id -u; cat /etc/passwd | wc -l' 2>&1) || true
if printf '%s' "$id_out" | head -1 | grep -qx 0; then
  pass "default user is root (required by s6 stage2)"
else
  bad "default user is not root: $(printf '%s' "$id_out" | head -1)"
fi

docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'test -x /app/docker/entrypoint.sh' \
  && pass "entrypoint present" || bad "entrypoint missing"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'test -f /etc/s6-overlay/s6-rc.d/studio/run && test -f /etc/s6-overlay/s6-rc.d/user/contents.d/studio' \
  && pass "studio s6 service installed into the user bundle" || bad "studio s6 service missing"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'command -v gh' >/dev/null \
  && pass "gh present" || bad "gh missing"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'command -v jq && command -v fd && command -v bat' >/dev/null \
  && pass "jq/fd/bat present" || bad "jq/fd/bat missing"

# glab and tea are installed from upstream releases (Debian's `tea` is a Qt editor),
# so their presence and runnability is worth asserting, not assuming.
glab_ver=$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'HOME=/tmp glab version 2>&1' || true)
case "$glab_ver" in
  glab\ *) pass "glab: ${glab_ver}" ;;
  *) bad "glab not runnable: ${glab_ver:-<empty>}" ;;
esac
tea_ver=$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'HOME=/tmp tea --version 2>&1' || true)
case "$tea_ver" in
  Version:\ *) pass "tea: ${tea_ver}" ;;
  *) bad "tea not runnable: ${tea_ver:-<empty>}" ;;
esac

if [ "$MODE" = "--quick" ]; then
  echo; [ "$fail" -eq 0 ] && echo "quick checks passed" || echo "checks FAILED"; exit "$fail"
fi

echo
echo "== booting container as root with HERMES_UID=${UID_ARG} =="
docker run -d --name "$NAME" \
  -e HERMES_UID="$UID_ARG" -e HERMES_GID="$GID_ARG" -e PORT="$PORT_ARG" \
  "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$NAME" curl -fsS -o /dev/null "http://127.0.0.1:${PORT_ARG}/" 2>/dev/null; then break; fi
  sleep 2
done

echo "== runtime checks =="
if docker exec "$NAME" sh -c "curl -fsS -o /dev/null \"http://127.0.0.1:${PORT_ARG}/\"" 2>/dev/null; then
  pass "studio answers on :${PORT_ARG}"
else
  bad "studio does not answer on :${PORT_ARG}"
  docker logs --tail 20 "$NAME" | sed 's/^/       /'
fi

docker exec "$NAME" sh -c 'test "$(id -u 1 2>/dev/null || echo 0)" = 0' >/dev/null 2>&1 || true
pid1_cmd=$(docker exec "$NAME" cat /proc/1/cmdline | tr '\0' ' ')
case "$pid1_cmd" in
  */init*|*s6-svscan*) pass "PID 1 is the s6 supervisor ($pid1_cmd)" ;;
  *) bad "PID 1 is not s6: $pid1_cmd" ;;
esac

svstat=$(docker exec "$NAME" /command/s6-svstat /run/service/studio 2>&1 || true)
case "$svstat" in
  up*) pass "s6 reports studio $svstat" ;;
  *) bad "s6 does not report studio up: $svstat" ;;
esac

studio_uid=$(docker exec "$NAME" sh -c \
  "ps -o uid= -p \$(pgrep -f 'dist/server/index.js' | head -1) 2>/dev/null | tr -d ' '" || true)
if [ "${studio_uid:-x}" = "$UID_ARG" ]; then
  pass "studio runs as uid ${UID_ARG} (non-root)"
else
  bad "studio uid is '${studio_uid:-?}', expected ${UID_ARG}"
fi

if as_hermes 'touch "$HOME/.permcheck" && rm -f "$HOME/.permcheck" && mkdir -p "$HOME/.config/p" && rmdir "$HOME/.config/p"'; then
  pass "\$HOME writable by hermes"
else
  bad "\$HOME not writable by hermes"
fi

if as_hermes 'gh --version' >/dev/null 2>&1; then pass "gh runs as hermes"; else bad "gh fails as hermes"; fi

hc_owner=$(docker exec "$NAME" stat -c '%u' /home/agent/.hermes 2>/dev/null || echo '?')
if [ "$hc_owner" = "$UID_ARG" ]; then
  pass "HERMES_HOME owned by uid ${UID_ARG} (stage2 chown worked)"
else
  bad "HERMES_HOME owner is ${hc_owner}, expected ${UID_ARG}"
fi

# The whole point of variant B: gateway install must no longer fall back to the
# "container runtime is your service manager" answer.
gi=$(docker exec "$NAME" sh -c 'hermes gateway install 2>&1' || true)
if printf '%s' "$gi" | grep -qi 'container runtime is your service manager'; then
  bad "gateway install still dispatches to the container backend"
elif printf '%s' "$gi" | grep -qiE 's6|profile create|auto-?register'; then
  pass "gateway install detects the s6 backend"
else
  note "gateway install output: $(printf '%s' "$gi" | head -2 | tr '\n' ' ')"
  bad "gateway install did not report the s6 backend"
fi

echo
echo "== shutdown semantics =="
docker exec "$NAME" sh -c "pkill -f 'dist/server/index.js'" >/dev/null 2>&1 || true
gone=0
for _ in $(seq 1 30); do
  if ! docker ps -q --filter "name=^/${NAME}$" | grep -q .; then gone=1; break; fi
  sleep 1
done
if [ "$gone" = 1 ]; then
  pass "container exits when the studio service dies (restart policy keeps working)"
else
  bad "container stayed up after studio died (finish script broken)"
fi

echo
[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "CHECKS FAILED"
exit "$fail"
