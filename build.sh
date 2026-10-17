#!/usr/bin/env bash
# Builds dist/MirrorDelta-<version>.zip with the apps/lua/MirrorDelta structure,
# ready to drag into Content Manager.
set -euo pipefail
cd "$(dirname "$0")"

APP=apps/lua/MirrorDelta
VERSION=$(sed -n 's/^VERSION *= *//p' "$APP/manifest.ini" | tr -d '\r')
ZIP="dist/MirrorDelta-$VERSION.zip"

mkdir -p dist
rm -f "$ZIP"
if command -v zip >/dev/null 2>&1; then
  zip -rqX "$ZIP" "$APP" -x '*.DS_Store' -x '*Thumbs.db'
else
  python3 - "$APP" "$ZIP" <<'PY'
import os, sys, zipfile
app, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(app):
        for name in files:
            path = os.path.join(root, name)
            z.write(path, path.replace(os.sep, "/"))
PY
fi
echo "Built $ZIP"
