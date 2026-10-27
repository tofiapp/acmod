#!/usr/bin/env bash
# Builds dist/KeyDrive-<version>.zip with extension/lua/joypad-assist/KeyDrive (and apps/lua/KeyDriveConfig,
# apps/lua/KeyDriveKeyboardTest), ready to drag into Content Manager. MirrorDelta keeps its own build.sh.
set -euo pipefail
cd "$(dirname "$0")"

CORE=extension/lua/joypad-assist/KeyDrive
APP=apps/lua/KeyDriveConfig
KBTEST=apps/lua/KeyDriveKeyboardTest
VERSION=$(sed -n 's/^VERSION *= *//p' "$CORE/manifest.ini" | tr -d '\r')
ZIP="dist/KeyDrive-$VERSION.zip"

PARTS=("$CORE")
[ -d "$APP" ] && PARTS+=("$APP")
[ -d "$KBTEST" ] && PARTS+=("$KBTEST")

mkdir -p dist
rm -f "$ZIP"
if command -v zip >/dev/null 2>&1; then
  zip -rqX "$ZIP" "${PARTS[@]}" -x '*.DS_Store' -x '*Thumbs.db'
else
  python3 - "$ZIP" "${PARTS[@]}" <<'PY'
import os, sys, zipfile
out, parts = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for part in parts:
        for root, _, files in os.walk(part):
            for name in files:
                if name in ("Thumbs.db", ".DS_Store"):
                    continue
                path = os.path.join(root, name)
                z.write(path, path.replace(os.sep, "/"))
PY
fi
echo "Built $ZIP"
