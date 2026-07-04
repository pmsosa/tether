# Tether

A tiny macOS menu-bar app that mounts your Android device's filesystem into
Finder over ADB — USB or WiFi. No kernel extension, no third-party mounting
software, nothing to install on the phone beyond USB debugging.

- Lives in the menu bar; auto-detects connected devices.
- One click to **mount** a device and browse it in Finder; one click to unmount.
- Periodic auto-detect plus a manual **Refresh**.
- Read, write, and delete files directly in Finder.

## How it works

Tether runs a small in-app WebDAV server backed by `adb`, and mounts it with
macOS's built-in `/sbin/mount_webdav`. That gives a real, live Finder volume
using only software that already ships with macOS. See [DESIGN.md](DESIGN.md)
for the full design and the mount-engine trade-offs.

## Requirements

- macOS 26+
- [`adb`](https://developer.android.com/tools/adb) (Android platform-tools).
  Install with: `brew install --cask android-platform-tools`
- On the phone: **USB debugging** enabled, and the Mac authorized (accept the
  on-device prompt).

## Build & run

```sh
./build.sh --dev      # build and run locally
./build.sh            # build an unsigned DMG (local testing)
./build.sh --sign     # build a signed + notarized DMG (needs Apple creds)
./build.sh --help     # all options
```

Tether is **not** distributed via the Mac App Store: it spawns `adb` and
`mount_webdav`, which the App Store sandbox forbids. Distribution is via a
Developer-ID-signed, notarized DMG.

## License

BSD-3-Clause — see [LICENSE](LICENSE). Made by Pedro M. Sosa.
