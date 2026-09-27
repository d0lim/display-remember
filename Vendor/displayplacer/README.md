# Bundled displayplacer engine

Upstream: [jakehilborn/displayplacer](https://github.com/jakehilborn/displayplacer)

Pinned revision: [`c23026eb3d73000eb1a14b45d82fd6dd08c921f5`](https://github.com/jakehilborn/displayplacer/tree/c23026eb3d73000eb1a14b45d82fd6dd08c921f5).

`src/` contains the unmodified C/Objective-C engine, private-framework headers, MonitorPanel bridge, and legacy v1.3.0 implementation from that revision. The engine identifies itself as `v1.5.0-dev`. Its [MIT license](LICENSE) and original copyright notice are retained separately from the Swift application's license.

## Build and integration

Run `scripts/build-engine.sh` from the repository root. The script supplies the macOS SDK and a macOS 13 deployment target, and builds the complete standalone helper. The packaged app includes it at `Contents/Helpers/displayplacer` together with the upstream license and these notices.

`display-remember displayplacer ...` passes arguments directly to this engine. No system or Homebrew displayplacer installation is required. The passthrough retains mode listing, legacy output, UUID/contextual/numeric-serial identifiers, resolution, refresh rate, color depth, scaling, origin, rotation, mirroring, enable/disable, mode numbers, and quiet handling.

Raw configuration commands apply immediately. Stable physical-monitor matching and profile previews belong to the Swift layer; they do not change upstream passthrough behavior.

## Inherited limitations

- Available modes depend on macOS, the display, and rotation. Some listed modes may fail or fall back to another mode.
- Omitting Hertz and color depth selects the highest matching refresh rate, then the highest matching color depth. Mode numbers are transient.
- In a mirror group, the first ID is the mode target. Group rotation applies to every member.
- Disabling a display is not physical power-off. Some setups require disconnecting and reconnecting the cable to re-enable it.
- Upstream UUID, contextual ID, and numeric serial selectors retain their original stability limitations. Use saved display-remember profiles for EDID-derived matching.
- Configuration runs in stages and is not atomic. An error or timeout can leave some changes applied; stopping the helper does not roll them back.
- Private APIs, argument parsing, and hardware behavior are inherited from upstream. OS updates, Intel Macs, DisplayLink, KVMs, and docks require separate compatibility checks. Including the full engine does not establish support for every hardware configuration.
