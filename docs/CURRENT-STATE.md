# Current state

The living state of **SideStep**. Read [AI-BOOTSTRAP.md](AI-BOOTSTRAP.md) first for
orientation and the repo map; this file is the detail, the gotchas, and what's open.

**Last update: 2026-07-30. Latest release: v0.2.7** (notarized DMG on GitHub Releases).
We pursue exactly one model — the user signs an unsigned `.ipa` with their own Apple
ID and installs it to their own device. See AI-BOOTSTRAP for the pipeline.

## What's shipping

- **Sign + install with the user's Apple ID.** Free/paid login (SMS 2FA), one cert
  persisted+reused per account, sign via **zsign** (SHA-256 CodeDirectory), install
  over USB via the bundled libimobiledevice helper. Multi-account (3 free slots each),
  multi-device, per-account **team picker** (free 7-day vs paid 1-year), menu-bar
  management (per-app Refresh / Remove-frees-slot, live `slots N/3`).
- **Wireless install/refresh over Wi-Fi (no cable).** Direct-IP install
  (`idevice_ipinstall`, `idevice_new_network` + pair-record by UDID). The load-bearing
  fix was answering the device's **heartbeat** (`com.apple.mobile.heartbeat` Marco/Polo
  pings) — without it iOS RSTs the AFC upload over Wi-Fi (the old "AFC error 34").
  `instproxy` must use a **NULL status callback** (a non-nil callback returned 0
  immediately and false-reported "INSTALL OK"). Upload streams `PROGRESS sent total`
  for a live %/ETA.
- **Self-updating beacon.** The `BeaconInject` dylib is injected into every installed
  app (runtime-configured via `BeaconConfig.plist`; shipped as an XOR blob so
  notarization never scans an iOS binary). The app pings the Mac's native
  `BeaconListener` (`_sidestep._udp` Bonjour + UDP :51234), which re-signs and pushes
  the newest build over Wi-Fi; the app self-`exit(0)`s ~2s after upload so iOS applies
  the swap on next launch.
  - **Permission prompts are deferred** so they don't freeze the launch screen:
    notifications 5s after launch, then Local Network. A refusal shows a **Try Again /
    I understand** card. Local-Network denial is detected via an NWBrowser policy-denied
    error (DNS `PolicyDenied` / POSIX `EPERM`) — *not* ENETDOWN (Wi-Fi merely off). The
    "Updating app now" popup is sized so its text doesn't wrap.
- **Keep-alive.** Re-sign past ~70% of the 7-day window, on a timer + on device-connect
  + every ~5 min near expiry. A manual refresh **sweeps every already-expired app on
  that device** and **silently re-logs-in** with the Keychain-stored password if the
  session lapsed (only a required 2FA code needs the user — `Sideloader.ensureSession`).
- **Anti-piracy blocklist.** `Blocklist.swift` + `blocklist.json` (bundled + refreshed
  from raw `main`): refuses known pirate sources, screens installs (hard-block known
  cracked files by hash, confirm before a paid App Store app). Designed for no false
  positives; hash lists seeded empty and grow.
- **In-app self-update.** Daily GitHub-Releases check → download the notarized DMG →
  verify `spctl --assess` accepted + `TeamIdentifier=XLS3XF57J8` → swap-on-quit →
  relaunch.
- **Docs & landing page.** Rewritten README + a GitHub **Pages** site
  (<https://johnbuckman.github.io/SideStep/>), auto-deployed from `docs/` via a GitHub
  Actions workflow (the legacy Jekyll build errored on the mixed `docs/` files, so we
  use `actions/upload-pages-artifact` + `deploy-pages` instead).

## Build gotchas that will waste your time

- **`swift build` can skip relinking** a changed module's executable → your edits
  "don't take." Both build scripts `rm -f` the binary first; do the same by hand:
  `rm -f "$(swift build --show-bin-path)/Provision"; swift build --product Provision`.
- **Menu-bar app + `NSOpenPanel`:** an `.accessory` app can't make a modal open panel
  the key window (the `.ipa` chooser greys out) → switch to `.regular` while it's open.
- **SIGPIPE on launch:** a diagnostics `Pipe` held in a local var dealloc'd, and the
  next write killed the app with `EXIT=141` on some Macs → `signal(SIGPIPE, SIG_IGN)`
  first thing + retain the pipe for the process lifetime.
- **Versioning contract:** `CFBundleShortVersionString` must equal the release tag, or
  the in-app updater's tag-vs-version comparison never fires.
- **CI on `main`:** a daily catalog-bot commit updates `sidestep-apps.json`; `git fetch`
  + rebase before pushing to avoid a non-fast-forward.

## Cutting a release

```bash
./notarize-build.sh                                     # dist/SideStep-<V>.dmg (signed); bumps VERSION.txt
xcrun notarytool submit dist/SideStep-<V>.dmg --keychain-profile bping-notary --wait
xcrun stapler staple dist/SideStep-<V>.dmg
gh release create v<V> --repo johnbuckman/SideStep --target main --prerelease \
  --title "SideStep Beta <V>" --notes-file notes.md dist/SideStep-<V>.dmg
git commit -am "release v<V>" && git push sidestep isl-main:main   # commit the VERSION bump
```

Create the tag on the commit whose `VERSION.txt` == `<V>` (i.e. before committing the
bump). `gh release --target` wants a branch name (`main`), not a short SHA.

## Open items / where to pick up

1. **Remove the dead OTA/ad-hoc code** now that we pursue only the user-signs model:
   `SideloaderKit/OTAHost.swift`, `IPAInspector.swift`, the QR/OTA + UDID-capture UI in
   `App.swift`, the `Helpers/idevice_*.c` mesh experiments, and `docs/wireless/` + the
   slide decks.
2. **Prompt for the 2FA code during a manual refresh** when Apple demands one (today it
   asks the user to re-open the sign-in flow).
3. **Seed `blocklist.json` `ipaSha256`/`binarySha256`** as specific cracked builds are
   identified (the mechanism runs on every install; the lists are currently empty).
4. **Wi-Fi reliability** — direct-IP + heartbeat works when the device is unlocked +
   paired + on the same network; USB remains the sure path, and iOS 17+ can need a
   tunnel in some cases.

## Not in this repo

- `~/altstore-fork/rebuild-app.sh` — John's local dev build script.
- The signing certificate (login Keychain) and account credentials.
