#!/usr/bin/env bash
# List published Studio tags and show when a tag was actually built.
# Uses the registry HTTP API only - no docker daemon needed.
set -euo pipefail

REPO="${REPO:-ekkoye8888/hermes-web-ui}"
ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TOKEN=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO}:pull" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')

api() { curl -fsS -H "Authorization: Bearer ${TOKEN}" -H "Accept: ${ACCEPT}" "$1"; }

list_tags() {
  echo "== published tags =="
  api "https://registry-1.docker.io/v2/${REPO}/tags/list?n=1000" > "$TMP/tags.json"
  python3 - "$TMP/tags.json" <<'PY'
import json, sys
tags = json.load(open(sys.argv[1])).get("tags") or []
print(len(tags), "tags")
print([t for t in tags if t.startswith("v")][-25:])
PY
}

show_tag() {
  local tag="$1"
  echo "== ${tag} =="
  if ! api "https://registry-1.docker.io/v2/${REPO}/manifests/${tag}" > "$TMP/m.json"; then
    echo "  NOT PUBLISHED"
    return 0
  fi
  local digest
  digest=$(python3 - "$TMP/m.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
ms = m.get("manifests")
if ms:
    pick = [x for x in ms if x["platform"].get("os") == "linux"
            and x["platform"].get("architecture") == "amd64"]
    print((pick or ms)[0]["digest"])
else:
    print("SELF")
PY
)
  if [ "$digest" != "SELF" ]; then
    api "https://registry-1.docker.io/v2/${REPO}/manifests/${digest}" > "$TMP/m.json"
  fi
  local cfg
  cfg=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["config"]["digest"])' "$TMP/m.json")
  curl -fsSL -H "Authorization: Bearer ${TOKEN}" \
    "https://registry-1.docker.io/v2/${REPO}/blobs/${cfg}" > "$TMP/cfg.json"
  python3 - "$TMP/cfg.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print("  created:", c.get("created"))
print("  User:", repr(c["config"].get("User")))
PY
}

if [ $# -eq 0 ] || [ "${1:-}" = "--list" ]; then
  list_tags
  [ $# -eq 0 ] && exit 0
  shift || true
fi
for tag in "$@"; do
  [ "$tag" = "--list" ] && continue
  show_tag "$tag"
done
