# App icon

`AppIcon.png` is the source for the app's minimal display glyph. The artwork was generated with an AI image tool and is distributed with this project under the [MIT license](../LICENSE), to the extent copyright applies.

Run `scripts/build-icon.sh` from the repository root to generate `AppIcon.icns`. The script creates the standard macOS icon sizes, retaining the source image's transparency. Packaging includes the icon for Finder, the Dock, and the app header.

The menu bar uses the monochrome `display.2` SF Symbol supplied by macOS.
