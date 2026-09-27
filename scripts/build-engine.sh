#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ENGINE_OUTPUT=${1:-"$PROJECT_DIR/.build/helpers/displayplacer"}
case "$ENGINE_OUTPUT" in
  /*) ;;
  *) ENGINE_OUTPUT="$PWD/$ENGINE_OUTPUT" ;;
esac
ENGINE_OUTPUT_DIR=$(dirname -- "$ENGINE_OUTPUT")
mkdir -p "$ENGINE_OUTPUT_DIR"
ENGINE_TEMP=$(mktemp "$ENGINE_OUTPUT_DIR/.displayplacer.XXXXXX")
trap 'rm -f "$ENGINE_TEMP"' EXIT HUP INT TERM
ENGINE_SDK=$(xcrun --sdk macosx --show-sdk-path)
ENGINE_SOURCE="$PROJECT_DIR/Vendor/displayplacer/src"

# Compile the complete, unmodified pinned upstream CLI, including legacy output.
xcrun --sdk macosx clang \
  -isysroot "$ENGINE_SDK" -mmacosx-version-min=13.0 -O2 \
  "-ffile-prefix-map=$PROJECT_DIR=." "-fdebug-prefix-map=$PROJECT_DIR=." \
  -I"$ENGINE_SOURCE" -F"$ENGINE_SOURCE/Headers" \
  -F"$ENGINE_SDK/System/Library/PrivateFrameworks" \
  "$ENGINE_SOURCE/DisplayPlacer.c" "$ENGINE_SOURCE/Legacy/v130.c" \
  -x objective-c "$ENGINE_SOURCE/MonitorPanel.m" \
  -framework IOKit -framework ApplicationServices -framework DisplayServices \
  -framework CoreDisplay -framework OSD -framework MonitorPanel -framework SkyLight \
  -Wno-deprecated-declarations -o "$ENGINE_TEMP"
xcrun strip -S -x "$ENGINE_TEMP"
chmod 755 "$ENGINE_TEMP"
mv -f "$ENGINE_TEMP" "$ENGINE_OUTPUT"
trap - EXIT HUP INT TERM
printf '%s\n' "$ENGINE_OUTPUT"
