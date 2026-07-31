# AI bootstrap — start here

You're an AI (or a new contributor) picking up **SideStep**. This orients you fast:
what it is, the one approach we pursue, where things live, and how to build. Read
this, then [CURRENT-STATE.md](CURRENT-STATE.md), then act.

## What SideStep is — and the ONE approach we pursue

A small, self-contained **macOS menu-bar app** that installs iOS apps onto a user's
own iPhone/iPad and keeps them signed — using **the user's own Apple ID**.

There is exactly **one model, on purpose** (earlier versions offered several install
paths, which people found confusing — EuroTcl 2026 feedback):

> The user starts from an **unsigned `.ipa`**, signs it on their Mac with **their own
> free (or paid) Apple ID**, and installs it to their own device. SideStep then keeps
> it re-signed automatically.

Concretely: **free-Apple-ID login → Apple dev certificate + provisioning profile (the
same ones Xcode uses) → sign the IPA with zsign on the Mac → install over USB (or
Wi-Fi) via libimobiledevice → auto re-sign every 7 days.** No jailbreak, no shared
certificate, no server, no companion app on the device.

We do **not** pursue the alternatives that were explored earlier — OTA /
`itms-services` distribution, paid ad-hoc 100-device profiles, on-device signing,
VPN-loopback refreshers, QR "refresh portals." Some dead code from those paths still
exists; see **Legacy code** below.

- **Public repo:** `johnbuckman/SideStep` (AGPL-3.0; zsign is MIT). Landing page:
  <https://johnbuckman.github.io/SideStep/>
- **Local code:** `~/altstore-fork/AltSign-SS` (a fork of SideStore/AltSign), branch
  `isl-main`, remote `sidestep` (push here — **not** `origin`, which is upstream AltSign).
- **Installed app:** `/Applications/AI Apps/SideStep.app` (menu-bar, `LSUIElement`).
- **Latest release:** notarized **v0.2.7** DMG on GitHub Releases.

## The pipeline (what actually runs)

1. **Login** — Apple-ID auth incl. SMS 2FA; "anisette" anti-abuse data generated
   locally (private `AOSKit`/`AuthKit`). One certificate is **persisted & reused per
   account** so re-signing one app doesn't invalidate the others.
2. **Sign** — `ALTSigner` → the native **zsign** bridge (`native_bridge_zsign_sign`),
   which emits a **SHA-256-primary CodeDirectory** (the format iOS 16–26 accept; the
   old ldid emitted SHA-1-primary → `0xe8008001`). Signed for that one user's device.
3. **Instrument** — a tiny **beacon** dylib is injected into the app (`LC_LOAD_DYLIB`;
   shipped as an XOR data blob so macOS notarization never scans an iOS binary). At
   runtime it pings the Mac so it can re-sign + push a fresh build over Wi-Fi.
4. **Install** — over USB via the bundled **libimobiledevice** helper (`Helpers/idevice`),
   or by **direct IP** over Wi-Fi (the device's beacon supplies its IP; a heartbeat
   keeps the AFC connection alive).
5. **Keep alive** — re-sign+reinstall past ~70% of the 7-day window, on a timer, on
   device-connect, and every ~5 min near expiry. A manual refresh sweeps every expired
   app on that device and silently re-logs-in via the Keychain password.
6. **Refuse piracy** — `Blocklist` screens every install and add-source (`blocklist.json`).

## Repo layout (the parts you'll touch)

| Path | What |
|---|---|
| `InstallerApp/App.swift` | SwiftUI menu-bar app: `AppModel`, `ContentView`, `RefreshDaemon`, install/refresh flows. |
| `SideloaderKit/Sideloader.swift` | The pipeline: `install/refreshOne/refreshAll/removeApp`, `ensureSession`, `AccountStore`/`CertStore`/`Tracked`, `connectedDevices`, `helperPath`/`ipInstallPath`. |
| `SideloaderKit/Blocklist.swift` + `blocklist.json` | Anti-piracy screening (bundled + refreshed from the repo). |
| `SideloaderKit/AltStoreCatalog.swift` + `sources.json` / `sidestep-apps.json` | The "Search AltStore" app catalog. |
| `BeaconInject/beacon_inject.m` + `build.sh` | The injected self-update beacon (built → `Helpers/beacon_payload.dat`). |
| `Sources/` (AltSign) | Apple-ID auth, anisette, provisioning, `ALTSigner`. |
| `NativeBridge/` | `native_bridge_zsign_sign` (ALTSigner → zsign). |
| `Helpers/idevice/` + `idevicehelper.c` | Bundled libimobiledevice tools (list/install/uninstall); `idevice_ipinstall.c` = direct-IP + heartbeat. |
| `notarize-build.sh` + `SideStep.entitlements` + `VERSION.txt` | Developer-ID + hardened + notarized DMG (notary profile `bping-notary`); auto-bumps VERSION. |
| `bundle-app.sh` | Repo-relative dev build → `SideStep.app`. |
| `~/altstore-fork/rebuild-app.sh` | John's local dev build (**not in repo**). |

## Build & run

```bash
cd ~/altstore-fork/AltSign-SS
swift build --product InstallerApp          # compile the app
~/altstore-fork/rebuild-app.sh              # bundle → /Applications/AI Apps/SideStep.app
open "/Applications/AI Apps/SideStep.app"   # menu-bar crate icon (no Dock icon)
```

- Beacon: `bash BeaconInject/build.sh` re-encodes `Helpers/beacon_payload.dat`.
- Release: `./notarize-build.sh` → notarize + staple → `gh release create` (see
  CURRENT-STATE). **Versioning contract:** `CFBundleShortVersionString` must equal the
  release tag or the in-app updater never fires.
- Logs: `~/Library/Logs/SideStep.log`; crash-safe `/tmp/sidestep.log`.

## Legacy code you can ignore (from the dropped approaches)

Not part of the current model — safe to ignore, and candidates for removal:
`SideloaderKit/OTAHost.swift`, `SideloaderKit/IPAInspector.swift`, the QR/OTA +
UDID-capture bits in `App.swift` (`startOTA`, `QRView`, `captureUDID`), the
`Helpers/idevice_*.c` Wi-Fi-mesh experiments (`idevice_netinstall`/`ipprobe`/`setwifi`,
`sweep.sh`), and the whole `docs/wireless/` research folder + `docs/SideStep.pdf` /
`.pptx` slide decks.

## Safety / conventions

- **Don't commit or push until asked** — review-first is the standing rule; push to
  `sidestep`, never `origin`.
- **Signing certs & keys are the user's** — never bulk-export Keychain credentials.
- **Test devices are the user's** — installs/uninstalls touch real hardware. Testing
  Apple ID: `johnbuckman@moodmixes.com` (free); paid team `XLS3XF57J8` (Decent). Never
  touch the user's primary Apple ID.
