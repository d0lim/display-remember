#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIGURATION=${1:-release}
case "$CONFIGURATION" in release|debug) ;; *) printf '%s\n' 'Usage: build-app.sh [release|debug]' >&2; exit 2 ;; esac
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
if [ -n "$NOTARY_PROFILE" ] && [ "$SIGNING_IDENTITY" = - ]; then
    printf '%s\n' 'NOTARY_PROFILE requires a Developer ID SIGNING_IDENTITY.' >&2
    exit 2
fi
VERSION=$(sed -nE 's/^[[:space:]]*public static let current[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' "$PROJECT_DIR/Sources/DisplayRememberCore/Version.swift")
case "$VERSION" in ''|*[!0-9.]*) printf '%s\n' 'Version.swift must contain exactly one numeric release version.' >&2; exit 2 ;; esac
if ! printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    printf '%s\n' 'Expected a MAJOR.MINOR.PATCH release version.' >&2
    exit 2
fi
for REQUIRED_NOTICE in LICENSE Vendor/displayplacer/LICENSE Vendor/displayplacer/README.md; do
    test -f "$PROJECT_DIR/$REQUIRED_NOTICE" || { printf 'Missing release notice: %s\n' "$REQUIRED_NOTICE" >&2; exit 2; }
done
cd "$PROJECT_DIR"

# Native SwiftPM avoids Xcode signing generated bundles in FileProvider folders.
# Remap both debug information and #filePath literals before removing symbols.
set -- --build-system native -c "$CONFIGURATION"
if [ "$CONFIGURATION" = release ]; then
    set -- "$@" -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_DIR=." \
        -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=." \
        -Xcc "-ffile-prefix-map=$PROJECT_DIR=." -Xcc "-fdebug-prefix-map=$PROJECT_DIR=."
fi
MACOSX_DEPLOYMENT_TARGET=13.0 swift build "$@"
BIN_DIR=$(swift build "$@" --show-bin-path)
mkdir -p "$PROJECT_DIR/dist"
BUILD_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/display-remember-build.XXXXXX")
DIST_STAGING=$(mktemp -d "$PROJECT_DIR/dist/.display-remember-stage.XXXXXX")
trap 'rm -rf "$BUILD_STAGING" "$DIST_STAGING"' EXIT HUP INT TERM
APP_DIR="$BUILD_STAGING/display-remember.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/DisplayRemember" "$APP_DIR/Contents/MacOS/DisplayRemember"
cp "$BIN_DIR/display-remember" "$APP_DIR/Contents/MacOS/display-remember"
RESOURCE_BUNDLE=display-remember_DisplayRememberAppSupport.bundle
test -d "$BIN_DIR/$RESOURCE_BUNDLE" || { printf '%s\n' 'Missing app localization resources.' >&2; exit 2; }
ditto --noextattr --norsrc "$BIN_DIR/$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/$RESOURCE_BUNDLE"
for LANGUAGE in en ko; do
    STRINGS="$APP_DIR/Contents/Resources/$RESOURCE_BUNDLE/$LANGUAGE.lproj/Localizable.strings"
    test -s "$STRINGS" || { printf 'Missing app strings: %s\n' "$LANGUAGE" >&2; exit 2; }
    plutil -lint "$STRINGS"
done
"$PROJECT_DIR/scripts/build-engine.sh" "$APP_DIR/Contents/Helpers/displayplacer"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE.txt"
cp "$PROJECT_DIR/Vendor/displayplacer/LICENSE" "$APP_DIR/Contents/Resources/displayplacer-LICENSE.txt"
cp "$PROJECT_DIR/Vendor/displayplacer/README.md" "$APP_DIR/Contents/Resources/displayplacer-NOTICE.md"
"$PROJECT_DIR/scripts/build-icon.sh"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Assets/AppIcon.png" "$APP_DIR/Contents/Resources/AppIcon.png"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>DisplayRemember</string>
  <key>CFBundleIdentifier</key><string>dev.d0lim.display-remember</string>
  <key>CFBundleName</key><string>display-remember</string>
  <key>CFBundleDisplayName</key><string>display-remember</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST
if [ "$CONFIGURATION" = release ]; then
    for EXECUTABLE in Contents/MacOS/DisplayRemember Contents/MacOS/display-remember Contents/Helpers/displayplacer; do
        xcrun strip -S -x "$APP_DIR/$EXECUTABLE"
        if LC_ALL=C grep -aFq "$PROJECT_DIR" "$APP_DIR/$EXECUTABLE"; then
            printf 'Release binary contains the private source directory: %s\n' "$EXECUTABLE" >&2
            exit 1
        fi
    done
fi
sign_component() {
    if [ "$SIGNING_IDENTITY" = - ]; then
        codesign --force --sign - "$1"
    else
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$1"
    fi
}
xattr -cr "$APP_DIR"
sign_component "$APP_DIR/Contents/Helpers/displayplacer"
sign_component "$APP_DIR/Contents/MacOS/display-remember"
sign_component "$APP_DIR/Contents/MacOS/DisplayRemember"
sign_component "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
if [ "$SIGNING_IDENTITY" != - ]; then
    if ! codesign --display --verbose=4 "$APP_DIR" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
        printf '%s\n' 'SIGNING_IDENTITY must select a Developer ID Application certificate.' >&2
        exit 2
    fi
fi
if [ -n "$NOTARY_PROFILE" ]; then
    NOTARY_ARCHIVE="$BUILD_STAGING/notary-upload.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$NOTARY_ARCHIVE"
    xcrun notarytool submit "$NOTARY_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json > "$BUILD_STAGING/notary-result.json"
    NOTARY_STATUS=$(plutil -extract status raw -o - "$BUILD_STAGING/notary-result.json")
    if [ "$NOTARY_STATUS" != Accepted ]; then
        printf 'Notarization did not succeed: %s\n' "$NOTARY_STATUS" >&2
        cat "$BUILD_STAGING/notary-result.json" >&2
        exit 1
    fi
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    codesign --verify --deep --strict "$APP_DIR"
fi

# Validate and package outside FileProvider-managed folders. Such folders can
# attach Finder metadata immediately after a copy, invalidating strict checks.
"$PROJECT_DIR/scripts/package-app.sh" "$APP_DIR"

# Copy fresh, then exchange complete bundles atomically; never merge old files.
STAGED_APP="$DIST_STAGING/display-remember.app"
ditto --noextattr --norsrc "$APP_DIR" "$STAGED_APP"
xattr -cr "$STAGED_APP"
xcrun swift "$PROJECT_DIR/scripts/replace-app.swift" "$STAGED_APP" "$PROJECT_DIR/dist/display-remember.app"
printf '%s\n' "$PROJECT_DIR/dist/display-remember.app"
