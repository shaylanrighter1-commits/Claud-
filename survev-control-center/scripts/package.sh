#!/usr/bin/env bash
# Builds dist/survev-control-center-<version>.zip containing a single top-level folder
# (unzip it, then Load unpacked -> that folder).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(node -p "require('./manifest.json').version")
NAME="survev-control-center"
OUT="dist/${NAME}-${VERSION}.zip"
STAGE=$(mktemp -d)
mkdir -p "$STAGE/$NAME" dist
tar --exclude='./dist' --exclude='./node_modules' --exclude='.DS_Store' --exclude='./.git' -cf - . | (cd "$STAGE/$NAME" && tar -xf -)
rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OLDPWD/$OUT" "$NAME" -x '*.DS_Store')
rm -rf "$STAGE"
echo "Created $OUT"
unzip -l "$OUT" | tail -n 1
