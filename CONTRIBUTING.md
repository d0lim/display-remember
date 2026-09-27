# Contributing

Issues and pull requests are welcome. Keep changes focused and describe the user-visible behavior they address.

## Development

Use a Mac with Xcode or compatible Swift tools and a macOS SDK. Apple Silicon is the initial release target.

```sh
scripts/build-engine.sh
swift test --build-system native
scripts/build-app.sh debug
```

The app bundle is written to `dist/display-remember.app`. The bundled CLI is at `dist/display-remember.app/Contents/MacOS/display-remember`.

Add regression tests for changes to parsing, identity matching, profile validation, restoration, and process handling. Use fixtures and fake processes for automated tests. Preserve argument-array execution, timeouts, and refusal to guess between ambiguous monitors.

## Hardware checks

For changes to native display APIs or configuration behavior, report the macOS version, Mac architecture, connection type, and relevant display or dock models. A successful build or unit test does not establish hardware compatibility.

Start with read-only inventory and profile previews. Test reconnection, wake, and restoration on hardware you control when those behaviors change. State which checks you performed and which remain untested. Keep disruptive display changes out of the default automated test suite.

## Privacy

Before attaching screenshots, profiles, or `scan` output, remove monitor serials, UUIDs, EDID hashes, usernames, and identifying file paths. Use consistent fictional replacements when relationships between displays matter. Do not include signing credentials or notarization tokens.

Report security issues using [SECURITY.md](SECURITY.md), rather than a public bug report containing exploit details.

## Upstream engine and assets

The displayplacer engine is pinned in `Vendor/displayplacer`. Changes to the pin or source must preserve its license and update the provenance notes. Explain any local patches and the upstream compatibility they affect.

The icon source is in `Assets`; `scripts/build-icon.sh` generates its macOS representations. Do not commit build output, personal profiles, or real hardware scan dumps.

Contributions are made under the project's [MIT license](LICENSE).
