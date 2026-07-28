# AI bootstrap — start here

You're an AI picking up the **SideStep** project. This file orients you fast: what it
is, where things live, the load-bearing facts, and how to build/test without breaking
things. Read this, then the linked docs, then act.

> **➡️ Then read [CURRENT-STATE.md](CURRENT-STATE.md).** It is the living, detailed
> state of the wireless work (QR/OTA install, install progress, Wi-Fi device
> registration): build gotchas that will otherwise waste your time, the ad-hoc
> signing recipe, verified findings, test recipes, and the open items to pick up.
> Where this file and CURRENT-STATE disagree about *current* state, trust that one.

## What SideStep is

A lean, self-contained **macOS menu-bar app** that installs and keeps iOS apps signed on
a user's devices using their own Apple ID — an alternative to AltStore/SideStore that
signs on the Mac. It grew out of diagnosing why an app failed to install via AltStore on
iOS 26 (root cause: AltStore/SideStore's `ldid` emits a **SHA-1-primary CodeDirectory**
that iOS 26 rejects with `0xe8008001`; **zsign/codesign emit SHA-256-primary** which
installs — so SideStep signs with **zsign**).

- **Public repo:** `johnbuckman/SideStep` (AGPL-3.0; zsign is MIT).
- **Local code:** `~/altstore-fork/AltSign-SS` (a fork of SideStore/AltSign).
- **Installed app:** `/Applications/AI Apps/SideStep.app`.
- **Shipped:** notarized `v0.2-alpha` DMG on GitHub Releases.

## Core flow (already built & shipping)

Free-Apple-ID login (SMS 2FA) → auto-provision (one cert **persisted & reused** per
account) → **zsign** sign → **bundled libimobiledevice** install over USB (no Python) →
in-app 7-day auto-refresh → multiple accounts (3 app slots each) + multi-device + per-app
manage, all from the menu bar. Multi-team accounts get a team picker (free 7-day vs paid
1-year). Signing is via `native_bridge_zsign_sign` (**not** macOS `codesign`).

## Repo layout (the parts you'll touch)

| Path | What |
|---|---|
| `InstallerApp/App.swift` | The SwiftUI menu-bar app: `RefreshDaemon`, `AppModel`, `ContentView`, `InstallerApp`. |
| `SideloaderKit/Sideloader.swift` | The pipeline: `AccountStore`, `CertStore`, `Tracked`, `install/refreshAll/refreshOne/removeApp`, `connectedDevices`, `helperPath`. |
| `Sources/` (AltSign) | Apple-ID auth, anisette, provisioning, `ALTSigner`. |
| `Helpers/idevice/` + `Helpers/idevicehelper.c` | Bundled libimobiledevice device tools (list/install/uninstall). |
| `Helpers/idevice_*.c`, `Helpers/sweep.sh` | **WIP** wireless-mesh tools (link a patched libimobiledevice; not yet wired into the app). |
| `docs/GUIDE.md` | End-user guide. |
| `docs/wireless/` | **The wireless install/refresh research — read this before any wireless work.** |
| `~/altstore-fork/rebuild-app.sh` | Local build → bundles `/Applications/AI Apps/SideStep.app` (writes Info.plist, copies OpenSSL.framework + AppIcon + `Helpers/idevice`, ad-hoc signs). **Not in repo.** |
| `AltSign-SS/bundle-app.sh` | Repo-relative equivalent of rebuild-app.sh. |
| `AltSign-SS/notarize-build.sh` + `SideStep.entitlements` | Developer-ID + hardened-runtime + notarized DMG build (notary keychain profile `bping-notary`). |

## The wireless work (2026-07-12) — the big recent effort

Investigated installing/refreshing **over the network instead of USB**, tested end to
end on real iOS 26 hardware over a **hostile Eero mesh**. **Read [`docs/wireless/`](wireless/)**
(9 files) for the full story. The load-bearing conclusions:

- **OTA install** (`itms-services://` + a free trusted-HTTPS host) is the **proven robust
  wireless path** — it worked *through* the mesh. The device **pulls** an Ad-Hoc-signed
  IPA over outbound HTTPS and the OS installs it; nothing connects *into* the device.
  **Requires a paid account + Ad-Hoc distribution signing** (`get-task-allow=false`);
  free/development signing is silently dropped by `installd`.
- Free trusted HTTPS for a LAN box: **`local-ip.co`** (public DNS `<dashed-ip>.my.local-ip.co`
  → LAN IP + an iOS-trusted **GlobalSign** wildcard cert). **Gotcha:** their `chain.pem`
  is a stale mismatched Sectigo chain — fetch the real GlobalSign G3 intermediate via the
  leaf's AIA.
- **Direct-IP install** (lockdown/AFC by IP, bypassing mDNS via an `idevice_new_network`
  patch) works on friendly networks and is free-tier compatible, but the Eero mesh
  **actively RSTs inbound dynamic high-port TCP**, so it's fragile there.
- **Beacon** (the device UDP-pings the Mac) gives zero-scan, DHCP-proof discovery and
  works through the mesh — but an **iOS app cannot reach its own `lockdownd`** (sandbox),
  which kills on-device self-install. SideStore solves that with a WireGuard **loopback
  VPN** + minimuxer (see `docs/wireless/07`).
- **Recommended UX:** a **QR "refresh portal"** — the Mac hosts a page listing every
  managed app with one-tap OTA links; SideStep shows a QR of the current URL. Expiry-proof
  (unlike a companion app).

## Build & run

```bash
cd ~/altstore-fork/AltSign-SS
swift build --product InstallerApp        # compile the app
~/altstore-fork/rebuild-app.sh            # bundle → /Applications/AI Apps/SideStep.app + ad-hoc sign
open "/Applications/AI Apps/SideStep.app"
```
- It's a **menu-bar app** (LSUIElement, no Dock icon) — look for the crate icon.
- Logs: `~/Library/Logs/SideStep.log`.
- For a shippable build: `./notarize-build.sh` (needs the Developer-ID cert + `bping-notary`).

## Safety / conventions (important)

- **Don't commit or push until asked.** The repo pushes are authorized per-request; the
  standing rule is review-first.
- **Signing certs & keys are the user's** — never bulk-export keychain credentials. The
  product signs with **zsign**, not codesign; a corrupt *codesign* identity does not
  affect production.
- **Test devices** belong to the user; installs/uninstalls touch real hardware. The
  throwaway free Apple ID for testing is `johnbuckman@moodmixes.com`; the paid team is
  `XLS3XF57J8` (Decent Espresso). Don't touch the user's primary Apple ID.
- Full session history and per-file detail is in the user's memory
  (`wireless_install_research.md` and `iwish_altstore_nested_dylib_fail.md`).

## Current open work

- Wire the **QR/OTA install path** into the app (a USB-vs-QR choice after picking an IPA;
  IPA file association so a double-clicked `.ipa` opens the app with those options).
- Fold `idevice_new_network` into the **bundled** libimobiledevice so the direct-IP tools
  link in production.
- Optionally: the SideStore-style VPN-loopback stack for a fully computer-free free-tier
  refresher (large effort; OTA is the better near-term path).
