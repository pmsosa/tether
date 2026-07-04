# Tether — Design Document

A small macOS menu-bar utility that detects Android devices over ADB (USB or
WiFi) and mounts their filesystem so it can be browsed and edited in Finder.

- **Author:** Pedro M. Sosa
- **License:** BSD-3-Clause
- **Status:** Implemented (phases 1–4) — verified end-to-end on a real device

---

## 1. Goals

- Live in the menu bar, unobtrusive and visually clean.
- Automatically detect Android devices reachable via ADB (USB or WiFi).
- Let the user mount a device with one click and browse it in Finder.
- Unmount cleanly with one click.
- Periodically poll for new/removed devices, plus a manual **Refresh**.
- An **About** entry: "Made by Pedro M. Sosa", the date, and BSD-3-Clause license.
- Zero setup on the phone beyond enabling USB debugging.
- Free.

## 2. Non-goals (v1)

- No file browser UI of our own — Finder is the UI.
- No app installation / screen mirroring / logcat / shell features.
- No Windows or Linux build.
- No cloud sync, backups, or file conversion.
- No editing of the mount engine's low-level behavior by the user.

## 3. Constraints & assumptions

- **Baseline: macOS 26+** on Apple Silicon and Intel. All target users are on
  macOS 26, so we build directly on Apple's native FSKit and require nothing
  else for mounting (no macFUSE, no FUSE-T).
- The user has (or is guided to install) `adb`.
- The phone has USB debugging enabled and the Mac is authorized (the RSA
  fingerprint prompt has been accepted on the device).
- Mounting is done by a bundled FSKit File System Extension (see §6).

---

## 4. User experience

### Menu-bar menu

```
 ●  Tether
 ────────────────────────────
  Devices
    Pixel 8 (USB)              ⌢ Mount
    Galaxy S21 (192.168.1.42)  ⌵ Unmount → in Finder
    Unknown device            (unauthorized)
 ────────────────────────────
  ↻  Refresh
  ⏻  Auto-detect          [on/off toggle]
  ⓘ  About
  ✕  Quit
```

- **Icon:** a single monochrome menu-bar glyph (SF Symbol, template image so it
  adapts to light/dark). A subtle filled/badged state indicates "≥1 device
  mounted."
- **Device rows:** show a friendly name + transport (USB or the WiFi IP).
  - `device` state → actionable Mount/Unmount.
  - `unauthorized` → greyed with a hint ("check your phone to allow").
  - `offline` → greyed.
- **Mount** → mounts and reveals the volume in Finder.
- **Unmount** → unmounts; row returns to Mount.
- **Refresh** → immediate rescan (same code path as the timer).
- **Auto-detect toggle** → enables/disables periodic polling (persisted).
- **About** → small window/alert: "Made by Pedro M. Sosa · <date> · BSD-3-Clause".
- **Quit** → unmounts everything, then exits.

### States to communicate

- No devices → "No devices found" placeholder row.
- adb not installed → replace device list with a "Set up ADB…" guide entry.
- Mount in progress → row shows a spinner / "Mounting…".
- Mount failure → row shows an error affordance with a "Why?" detail.

---

## 5. Architecture

Native macOS app, Swift + SwiftUI, running as a menu-bar-only agent.

```
┌───────────────────────────────────────────────────────────┐
│ Tether.app  (LSUIElement, no Dock icon)                    │
│                                                            │
│  ┌──────────────┐   ┌───────────────┐   ┌───────────────┐  │
│  │ MenuBarExtra │──▶│  AppState     │──▶│  DeviceStore  │  │
│  │  (SwiftUI)   │   │ (ObservableO.)│   │  [Device]     │  │
│  └──────────────┘   └───────┬───────┘   └───────────────┘  │
│                             │                              │
│         ┌───────────────────┼────────────────────┐         │
│         ▼                   ▼                    ▼         │
│  ┌────────────┐     ┌──────────────┐     ┌──────────────┐  │
│  │ AdbLocator │     │ AdbClient    │     │ MountManager │  │
│  │ find adb   │     │ run adb …    │     │ mount/umount │  │
│  └────────────┘     └──────┬───────┘     └──────┬───────┘  │
└────────────────────────────┼────────────────────┼─────────┘
                             ▼                    ▼
                        `adb` binary       FSKit extension
                        (subprocess)       (mount engine, §6)
```

The FSKit File System Extension is a separate bundled target (appex) that also
talks to `adb`; the main app and the extension coordinate via the mount request
and a small amount of shared configuration (device serial, scope).

### Components

- **AdbLocator** — finds the `adb` executable (§7). Publishes availability.
- **AdbClient** — thin async wrapper over `adb` subprocess calls
  (`adb devices -l`, `adb -s <serial> shell …`, `adb pull/push`). Serializes
  and parses output. No third-party ADB library needed for v1.
- **DeviceStore** — the current list of `Device` values, diffed on each scan so
  the menu only re-renders on real changes.
- **MountManager** — owns the lifecycle of each mount: allocate a mount point
  under `~/Tether/<device>/`, start the bridge, wait until the volume is
  ready, reveal in Finder, and tear it down on unmount/quit.
- **AppState** — orchestrates the poll timer, wires actions to managers, and is
  the single `ObservableObject` the menu binds to.

### `Device` model (sketch)

```swift
struct Device: Identifiable, Equatable {
    let serial: String          // "39281FDH2000LT" or "192.168.1.42:5555"
    let transport: Transport    // .usb / .wifi(host:port)
    let state: DeviceState      // .ready / .unauthorized / .offline
    let model: String?          // from `adb devices -l` (e.g. "Pixel_8")
    var mount: MountState       // .unmounted / .mounting / .mounted(URL) / .failed
    var id: String { serial }
}
```

- **Transport detection:** a serial of the form `host:port` (IP + port) is WiFi;
  anything else is USB. `adb devices -l` also reports `usb:` / `transport_id`.

---

## 6. Mount engine (the core technical decision)

macOS has no built-in ADB or MTP filesystem, so a userspace filesystem layer is
required. Options evaluated:

| Approach | Phone setup | macOS friction | License fit | Verdict |
|---|---|---|---|---|
| **WebDAV + built-in `mount_webdav`** | USB debugging | Nothing to install — ships with macOS; no kext, no entitlement | Clean (our own code) | **Chosen / implemented** |
| FSKit extension (native) | USB debugging | Needs Xcode appex + Apple `fskit.fsmodule` entitlement; won't run unsigned | Clean | Future path — too heavy for a `swift build` pipeline |
| FUSE-T + our bridge | USB debugging | Kext-less, but a third-party package users must install | Clean | Rejected — extra dependency |
| macFUSE + adbfs bridge | USB debugging | Kernel extension; reboot into recovery to approve on Apple Silicon | — | Too much friction |
| sshfs-over-adb | Install Termux + sshd on phone | Per-phone setup | Clean | Not "simple" for users |
| MTP | none | Flaky, USB-only, not a real path FS | — | Rejected |

### Decision (as implemented)

Expose the device over an **in-app WebDAV server** and mount it with macOS's
built-in **`/sbin/mount_webdav`**. This is the same "userspace network volume"
idea as FUSE-T, but using only software that already ships with macOS — no
kext, no third-party package, and no Apple File System Extension entitlement.

- A tiny HTTP/1.1 + WebDAV server (`WebDAVServer` / `DAVConnection`, built on the
  `Network` framework) binds to an ephemeral **loopback-only** port.
- **Volume-aware root:** the volume root is *not* `/sdcard`. `/sdcard` is only a
  symlink to internal storage and hides removable cards. Instead the server
  presents a synthetic root listing every storage volume — **Internal storage**
  (`/storage/emulated/0`) and each removable card / USB drive (`/storage/<id>`,
  discovered via `ls /storage`). The first path segment selects the volume; the
  rest maps to that volume's device path.
- WebDAV verbs map to `adb -s <serial>` commands:
  - **PROPFIND** (dir listing / stat) → `adb shell ls -laL` (`-L` dereferences
    symlinks so directories browse correctly).
  - **GET** → `adb exec-out cat <path>`.
  - **PUT** → write body to a temp file, `adb push`.
  - **MKCOL / DELETE / MOVE / COPY** → `mkdir` / `rm -rf` / `mv` / `cp -r`.
  - **LOCK/UNLOCK** → synthetic tokens so Finder proceeds with writes.
- `mount_webdav -v <name> http://127.0.0.1:<port>/ ~/Tether/<name>` mounts it as
  a Finder volume. Nothing is installed on the phone (USB debugging only) and
  nothing extra is installed on the Mac. Works identically over USB and WiFi ADB.

**Why WebDAV over native FSKit:** FSKit is the cleanest *conceptually*, but a
File System Extension requires an Xcode app-extension target and the
Apple-provisioned `com.apple.developer.fskit.fsmodule` entitlement, and it won't
run unsigned. That is incompatible with a simple `swift build` pipeline and with
a free, zero-friction install. `mount_webdav` needs none of that and is present
on every macOS. The whole project stays BSD-3 (no GPL adbfs code).

**Trade-offs / limitations:**
- macOS's WebDAV client caches aggressively and reads whole files, so this is
  tuned for browse/copy rather than heavy in-place editing of huge files.
- `GET` currently buffers a file in memory (`exec-out cat`); very large files are
  a future streaming optimization.
- `umount` can report "resource busy" right after use; `MountManager` falls back
  to `diskutil unmount force`.

**Future path:** a native FSKit backend remains an option once the project has an
Xcode target and provisioning, and would remove the WebDAV layer entirely.

### Mount lifecycle

1. User clicks **Mount** on a `.ready` device.
2. `MountManager` starts a `WebDAVServer` for the device on a loopback port.
3. It creates `~/Tether/<name>/` and runs `mount_webdav` against the server.
4. On success, `NSWorkspace.open` reveals the volume in Finder.
5. Row shows **Show in Finder / Unmount**.
6. **Unmount** (or Quit) unmounts the volume and stops the server.

### Known limitations (documented for users)

- Large files copy on open/close (per-file `adb pull`/`push`), so this is best
  for browsing and copying, not heavy in-place editing.
- Some system paths need root and will be inaccessible on non-rooted phones —
  scoped to shared storage (`/sdcard`) by default.

---

## 7. Dependency detection & guidance

### adb

- Search, in order: `$PATH`, `/opt/homebrew/bin/adb`, `/usr/local/bin/adb`,
  `~/Library/Android/sdk/platform-tools/adb`, `/Applications/…` common spots.
- Persist a working path once found.
- If not found: menu shows **"Set up ADB…"** opening a small guide
  (`brew install --cask android-platform-tools`, or a download link).

### Mount engine

- No third-party mount dependency: the WebDAV server is in-app and
  `mount_webdav` ships with macOS. Nothing to detect or install.
- Mount failures surface on the device row (with the `mount_webdav` error).

The `adb` check is cheap and runs at launch and before the first mount.

---

## 8. Polling & performance

- Default poll interval: **~4 s** when Auto-detect is on (tunable constant).
- Each poll is a single `adb devices -l`; diffed against DeviceStore so the UI
  updates only on change.
- Polling pauses while a scan is in flight (no overlap) and while the menu is
  closed can drop to a slower cadence to save power (optional refinement).
- All `adb` calls are async off the main thread; UI updates on the main actor.

## 9. Persistence

`UserDefaults`:

- Auto-detect on/off.
- Discovered `adb` path.
- Poll interval override (if we expose one later).

## 9a. Exit & cleanup (never leave a dangling volume)

A dead in-app WebDAV server leaves macOS's `webdavfs_agent` holding a broken
mount, so unmounting on exit matters. Three layers cover every exit path
(`AppDelegate` + `MountManager.sweepStaleMounts`):

- **Quit / Cmd-Q / logout / shutdown** → `applicationShouldTerminate` returns
  `.terminateLater`, unmounts every volume, then replies to allow termination.
- **SIGTERM / SIGINT** (`kill <pid>`, Ctrl-C) → a `DispatchSource` signal
  handler force-unmounts all Tether volumes and removes their mount-point dirs,
  then exits.
- **SIGKILL / crash / power loss** (uncatchable) → the next launch runs a
  **startup sweep**: inspect the mount table, `diskutil unmount force` any
  leftover `~/Tether/*` volume, and `rmdir` the empty mount points.

The sweep is filesystem/mount-table driven (no dependency on in-memory state),
uses `rmdir` (empty-only, never recursive) for safety, and was verified against
a real dangling mount produced by `kill -9`.

## 10. Security & privacy

- No network calls of our own; everything is local `adb` + local mount.
- We never store device contents; temp read-cache lives under a scoped temp dir
  and is cleared on unmount/quit.
- Respects the on-device ADB authorization prompt — we can't bypass it, by
  design.

## 11. Packaging

- Single `.app` (`LSUIElement = true`, menu-bar only, no Dock icon), built from a
  SwiftPM package via `build.sh` (`swift build` + manual bundle assembly).
- **Not sandboxed / not Mac App Store eligible:** the app spawns `adb` and
  `/sbin/mount_webdav` and opens a loopback socket, which the App Sandbox
  forbids. Distribution is **Developer-ID signed + notarized** (hardened
  runtime) via `./build.sh --sign`.
- Does **not** bundle `adb` (auto-detect + guide instead); the mount engine uses
  built-in `mount_webdav`, so there is no other dependency to ship. BSD-3.
- Distributed free (direct download / GitHub release; Homebrew cask a follow-up).
- `build.sh` flags: unsigned DMG (default), `--dev` (run locally), `--sign`
  (notarized DMG), `--release` (GitHub release), `--bump <part>`.

## 12. About box

Exactly:

> **Tether**
> Made by Pedro M. Sosa · 2026 · BSD-3-Clause

(Rendered from build metadata; year/date pulled at build time.)

---

## 13. Proposed build phases

1. **Skeleton** — MenuBarExtra agent app, About, Quit, Auto-detect toggle,
   persistence. No device logic yet.
2. **Discovery** — AdbLocator + AdbClient + DeviceStore; live device list with
   states, polling, Refresh. (No mounting yet — proves detection.)
3. **Mount engine** — in-app WebDAV server + `mount_webdav`; browse in Finder,
   unmount. ✅ *Done — verified end-to-end on a real device.*
4. **Write support** — PUT→`adb push`, MKCOL/DELETE/MOVE/COPY. ✅ *Done —
   read/write/delete verified through the mounted volume.*
5. **Polish** — app icon, streaming large-file reads, signing/notarization,
   power-aware polling. *(remaining)*

Phases 1–4 are implemented; the app builds, launches as a menu-bar agent, and
mounts a device's `/sdcard` into Finder with working read/write/delete.

## 14. Open questions / risks

- **Large-file reads:** `GET` buffers the whole file (`exec-out cat`); stream it
  for big media.
- **WebDAV client quirks:** macOS caching and occasional "resource busy" on
  unmount (handled with a `diskutil unmount force` fallback); watch for edge
  cases with unusual filenames / very large directories.
- **Scope:** the synthetic root exposes all `/storage` volumes (internal + SD /
  USB). Paths that need root (outside `/storage`) remain inaccessible on
  non-rooted phones — expected.
- **Multiple devices / same model:** disambiguation in the menu and mount paths.
- **App name:** **Tether** (settled). Note the project *directory* is still
  `ADBBrowser` — rename the folder if you want it to match.
- **Icon + notarization:** add `build/AppIcon.icns` and run `./build.sh --sign`.
```
