#!/usr/bin/env bash
# Builds one ZIP per app, dist/<App>-<version>.zip, each holding only apps/lua/<App>/...,
# ready to drag into Content Manager.
#   ./build.sh               both apps
#   ./build.sh MirrorDelta   one app (MirrorDelta or LedControl)
# Each app's tests run first (./run_tests <App>); a failing test stops the build.
set -euo pipefail
cd "$(dirname "$0")"

build() {
  local name=$1
  local app="apps/lua/$name"
  [ -f "$app/manifest.ini" ] || { echo "Unknown app: $name" >&2; exit 1; }
  # no ZIP from red tests
  if ! ./run_tests "$name"; then
    echo "Tests of $name failed: no ZIP built." >&2
    exit 1
  fi
  local version
  version=$(sed -n 's/^VERSION *= *//p' "$app/manifest.ini" | tr -d '\r')
  local zip="dist/$name-$version.zip"
  mkdir -p dist
  rm -f "$zip"
  if command -v zip >/dev/null 2>&1; then
    zip -rqX "$zip" "$app" -x '*.DS_Store' -x '*Thumbs.db'
  else
    python3 - "$app" "$zip" <<'PY'
import os, sys, zipfile
app, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(app):
        for name in files:
            if name in ("Thumbs.db", ".DS_Store"):
                continue
            path = os.path.join(root, name)
            z.write(path, path.replace(os.sep, "/"))
PY
  fi
  echo "Built $zip"
}

if [ $# -eq 0 ]; then
  set -- MirrorDelta LedControl
fi
for name in "$@"; do build "$name"; done
