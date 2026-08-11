# SideStep regression tests

An automated suite that verifies SideStep actually works — installs land, uninstalls
remove, versions match, extensions install, App IDs are reused, and the on-device beacon
responds — **asserted against the device itself, never against SideStep's own success
message.**

## Why it works this way

SideStep's recurring failure mode is *claiming success it never verified* — e.g. the USB
installer once printed `INSTALL OK` before `installd` had actually installed anything. So
the suite is built on two rules:

1. **Independent ground truth.** After any operation, assert against what `installd`
   *actually* reports on the device (`idevicehelper apps/appinfo`), not SideStep's claim.
2. **A scriptable control surface** on both ends — a headless `Provision` CLI on the Mac and
   a control channel on the injected device beacon — so tests run with no human in the loop.

## Running it

```bash
./regression/regress.sh            # run everything against the USB-connected device
./regression/regress.sh 01-logic   # run named scenario(s) only
```

The runner auto-detects whichever iOS device is on USB, uses the paid `johnbuckman@mac.com`
account (no signing limits), and prints `PASS` / `FAIL` / `SKIP` with a strict
present / absent / **error** distinction so a device-comms failure can never masquerade as a
passing test. Requires a Mac with the repo built (`swift build --product Provision`) and the
bundled `Helpers/idevice/` tools.

## What it covers

| Scenario | Tier | Asserts |
|---|---|---|
| `00-oracle`    | ground truth | `installd` browse works; a known app resolves; a bogus id reports ABSENT |
| `01-logic`     | A (no device) | `GitHub.normalizeRepo`; AltStore v1 + v2 `versions[]` parse; `VersionCompare.isNewer`; `installFailReason`; `isDeviceLimitError`; `wifiPairingHint` |
| `02-install`   | B (device) | build a random-versioned app → install → **installd shows that exact version** → uninstall → ABSENT |
| `03-extension` | B (device) | same, for an app with a nested `.appex` (the extension-bundle-id nesting path) |
| `05-appid`     | B (device) | reinstall **reuses** the same `com.sidestep.<name>.<team>` id (Apple caps *new* App IDs at 10 / 7 days) |
| `04-beacon`    | C (device) | the on-device beacon dials the Mac and answers `PING` + real `STATE`; SKIPs unless a test app is foregrounded with Local Network granted |

Each device scenario installs a tiny, version-stamped test app built by
`regression/build-test-app.sh` (a plain app, plus a `--ext` variant carrying a real
`.appex`). A distinct random version each run proves a genuine re-sign+install, not a cache.

## Architecture

- **Device oracle** — `Helpers/idevice/idevicehelper apps <udid>` / `appinfo <udid> <bundleid>`
  query `installd` directly for the real installed bundle-id + version.
- **Headless driver** — `Provision` (SwiftPM target): `--selftest` (Tier-A logic),
  `--app <path>` (sign+install), `--uninstall <bundleid>`, `--beacon-serve <CMD>` (the
  Mac-side end of the beacon control channel).
- **Beacon control channel** — on launch the injected beacon **dials out** to the Mac
  (`g_macIP:51236`) — the reliable direction — and answers token+LAN-gated commands:
  `PING`, `STATE` (JSON: version, beacons, lnGranted, autoUpdates, macIP, profileExpiry),
  `BEACON`, `UPDATE`, `NEXT` (drives the app's own "Local network access → Next" button).
  Config is baked into each install's `BeaconConfig.plist`.

## Known gotchas

- **`devicectl` ↔ usbmux contention.** Apple's `xcrun devicectl` (the only clean way to
  launch an app on iOS 17+) uses the CoreDevice tunnel, which wedges the `libimobiledevice`
  install path until a **USB replug**. Don't interleave it with the install/oracle tests —
  open the test app by hand instead, then run `04-beacon`.
- **The beacon needs a one-time Local Network grant** (open the app → Next → iOS "Allow").
  The app can't tap the system "Allow"; `NEXT` only drives the app's own card.
- **Installing over a *running* app defers the swap** — `installd` reports OK but the old
  version keeps running until the app exits. The suite pre-cleans (uninstalls any running
  instance) before each install so version asserts are reliable.
- If installs hang, **replug the USB cable** to clear any CoreDevice tunnel contention.

## Adding a scenario

Drop a `regression/scenarios/NN-name.sh` file; it's sourced by the runner with `$UDID`,
`$PROVISION`, `$HELPER`, and the assertion helpers (`assert_device_installed`,
`assert_device_version`, `assert_device_absent`, `install_uninstall_cycle`, `pass`/`fail`/`skip`)
already in scope. Always assert against the oracle, never SideStep's stdout.
