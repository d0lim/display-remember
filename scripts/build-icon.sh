#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ICON_MASTER="$PROJECT_DIR/Assets/AppIcon.png"
ICON_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/display-remember-icon.XXXXXX")
trap 'rm -r -- "$ICON_STAGING"' EXIT
ICONSET="$ICON_STAGING/AppIcon.iconset"
mkdir -p "$ICONSET"

# Preserve the master's alpha while creating Apple's standard 1x and 2x sizes.
for POINT_SIZE in 16 32 128 256 512; do
    DOUBLE_SIZE=$((POINT_SIZE * 2))
    sips -z "$POINT_SIZE" "$POINT_SIZE" "$ICON_MASTER" --out "$ICONSET/icon_${POINT_SIZE}x${POINT_SIZE}.png" >/dev/null
    sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$ICON_MASTER" --out "$ICONSET/icon_${POINT_SIZE}x${POINT_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$PROJECT_DIR/Assets/AppIcon.icns"
printf '%s\n' "$PROJECT_DIR/Assets/AppIcon.icns"
