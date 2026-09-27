#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 1 ]; then
    printf '%s\n' 'Usage: package-app.sh /path/to/display-remember.app' >&2
    exit 2
fi
case "$1" in /*) APP_DIR=$1 ;; *) APP_DIR="$PWD/$1" ;; esac
APP_DIR=${APP_DIR%/}
if [ "$(basename -- "$APP_DIR")" != display-remember.app ]; then
    printf '%s\n' 'The bundle must be named display-remember.app for the release archive.' >&2
    exit 2
fi
test -d "$APP_DIR/Contents" || { printf '%s\n' 'Expected a macOS application bundle.' >&2; exit 2; }
INFO="$APP_DIR/Contents/Info.plist"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$INFO")
case "$VERSION" in ''|*[!0-9.]*) printf '%s\n' 'Invalid bundle version.' >&2; exit 2 ;; esac
if ! printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    printf '%s\n' 'Expected a MAJOR.MINOR.PATCH bundle version.' >&2
    exit 2
fi
if [ "$(plutil -extract CFBundleIdentifier raw -o - "$INFO")" != dev.d0lim.display-remember ] || \
   [ "$(plutil -extract CFBundleExecutable raw -o - "$INFO")" != DisplayRemember ]; then
    printf '%s\n' 'Bundle identity or GUI executable is inconsistent with display-remember.' >&2
    exit 2
fi

# Preserve an already signed/stapled app. Never rebuild, strip, re-sign, alter
# attributes, or staple in this script.
codesign --verify --deep --strict "$APP_DIR"
EXPECTED_ARCHS=
for EXECUTABLE in Contents/MacOS/DisplayRemember Contents/MacOS/display-remember Contents/Helpers/displayplacer; do
    FILE="$APP_DIR/$EXECUTABLE"
    test -f "$FILE" && test -x "$FILE" || { printf 'Missing executable: %s\n' "$EXECUTABLE" >&2; exit 2; }
    codesign --verify --strict "$FILE"
    CURRENT_ARCHS=$(lipo -archs "$FILE" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | paste -sd ' ' -)
    if [ -z "$EXPECTED_ARCHS" ]; then EXPECTED_ARCHS=$CURRENT_ARCHS; fi
    if [ "$CURRENT_ARCHS" != "$EXPECTED_ARCHS" ]; then
        printf 'Executable architectures differ: %s\n' "$EXECUTABLE" >&2
        exit 2
    fi
done
case "$EXPECTED_ARCHS" in
    arm64) ARCH=arm64 ;;
    x86_64) ARCH=x86_64 ;;
    'arm64 x86_64') ARCH=universal ;;
    *) printf 'Unsupported release architectures: %s\n' "$EXPECTED_ARCHS" >&2; exit 2 ;;
esac
CLI_VERSION=$("$APP_DIR/Contents/MacOS/display-remember" --version)
if [ "$CLI_VERSION" != "display-remember $VERSION" ]; then
    printf '%s\n' 'Bundled CLI version does not match Info.plist.' >&2
    exit 2
fi
for NOTICE in LICENSE.txt displayplacer-LICENSE.txt displayplacer-NOTICE.md; do
    test -f "$APP_DIR/Contents/Resources/$NOTICE" || { printf 'Missing bundled license/notice: %s\n' "$NOTICE" >&2; exit 2; }
done
for LANGUAGE in en ko; do
    STRINGS="$APP_DIR/Contents/Resources/display-remember_DisplayRememberAppSupport.bundle/$LANGUAGE.lproj/Localizable.strings"
    test -s "$STRINGS" || { printf 'Missing app strings: %s\n' "$LANGUAGE" >&2; exit 2; }
    plutil -lint "$STRINGS"
done
mkdir -p "$PROJECT_DIR/dist"
PACKAGE_STAGING=$(mktemp -d "$PROJECT_DIR/dist/.display-remember-package.XXXXXX")
trap 'rm -rf "$PACKAGE_STAGING"' EXIT HUP INT TERM
ARCHIVE_NAME="display-remember-$VERSION-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$PACKAGE_STAGING/$ARCHIVE_NAME"
(
    cd "$PACKAGE_STAGING"
    shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)
mv -f "$PACKAGE_STAGING/$ARCHIVE_NAME" "$PROJECT_DIR/dist/$ARCHIVE_NAME"
mv -f "$PACKAGE_STAGING/$ARCHIVE_NAME.sha256" "$PROJECT_DIR/dist/$ARCHIVE_NAME.sha256"
printf '%s\n' "$PROJECT_DIR/dist/$ARCHIVE_NAME" "$PROJECT_DIR/dist/$ARCHIVE_NAME.sha256"
