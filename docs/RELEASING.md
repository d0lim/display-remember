# Releasing

The version in `Sources/DisplayRememberCore/Version.swift` is shared by the CLI
and app bundle. The public Homebrew cask currently targets Apple Silicon.

## Validate

Run `swift test --build-system native`, then build and inspect the app. Use
`DisplayRemember --render-demo OUTPUT.png` for screenshots containing fictional
data. Do not publish real profiles, scan output, local notes, or signing files.

Also render `--render-demo-ko`, `--render-settings-demo`, and
`--render-settings-demo-ko` to check both languages in the packaged app. These
modes use memory-only preferences and do not register login items. Check language
switching and the login toggle in an installed app before claiming manual coverage;
synthetic launch-event tests do not replace a real logout/login check.

## Sign and package

On an Apple Silicon Mac with a Developer ID Application certificate and a saved
notarytool Keychain profile:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-notary-profile' \
scripts/build-app.sh
```

Without those environment variables, the script produces an ad-hoc-signed local
build. Local or CI builds must not be represented as notarized releases.

If using Xcode to notarize an archive, export the notarized app and package it
without rebuilding or re-signing:

```sh
xcrun stapler validate /path/to/display-remember.app
spctl --assess --type execute --verbose=2 /path/to/display-remember.app
scripts/package-app.sh /path/to/display-remember.app
```

Packaging writes `dist/display-remember-VERSION-arm64.zip` and its `.sha256`
file. Verify the signature and Gatekeeper assessment of a freshly extracted
copy, and check both the app and CLI. Keep the final ZIP immutable after
computing its checksum.

## Publish

1. Commit the release changes, push `main`, and wait for CI.
2. Create and push an annotated `vVERSION` tag for the tested commit.
3. Create a GitHub release with the versioned ZIP and `.sha256` file. State
   signing status, platform requirements, notable changes, and testing limits.
4. Run `scripts/update-cask.sh /path/to/homebrew-tap` to update the cask from the
   final local ZIP. Review the version, URL, and checksum before committing it.
5. Run Homebrew style/audit checks, push the tap, and verify a download from the
   published URL has the expected checksum.

Do not disable Gatekeeper or remove quarantine attributes as part of the cask.
Release credentials belong in the macOS Keychain or protected CI secrets, never
in this repository.
