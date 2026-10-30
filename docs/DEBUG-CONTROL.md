# SideStep Mac debug control channel

A token-gated local socket that lets a script drive the SideStep Mac app with no mouse:
open the menu-bar panel and every window, prompt and dialog, fill fields, press buttons,
and save PNG snapshots of SideStep's own windows. It is the Mac-side twin of the beacon's
debug port (`BeaconInject/beacon_inject.m`, see REGRESSION-TESTS.md). Uses: regression
tests, help-page screenshots, explainer videos.

Code: `InstallerApp/DebugControl.swift`. Client: `regression/ssctl`.

## Turning it on

It is **off** unless a token exists. Either:

- set `SIDESTEP_DEBUG_TOKEN` in SideStep's environment, or
- create `~/Library/Application Support/SideStep/debug-token` containing a random string,
  `chmod 600` (a group/world-readable file is refused).

```bash
(umask 077; openssl rand -hex 16 > ~/Library/Application\ Support/SideStep/debug-token)
```

Then (re)start SideStep. It listens on **127.0.0.1:51238** only. Delete the file and restart
to turn it off.

## Protocol

One command per line, `"<token> CMD args…"`; args are space-separated and `"double quotes"`
group words. Each command gets exactly one reply line: JSON for queries, `OK…` or `ERR…`.
`regression/ssctl` adds the token and quoting for you:

```bash
regression/ssctl PING                      # PONG 0.2.71
regression/ssctl PANEL open
regression/ssctl SNAP panel ~/Desktop/panel.png 2
regression/ssctl DO github-prompt          # opens the NSAlert, replies first
regression/ssctl TYPE alert "owner/name" 15
regression/ssctl CLICK Cancel
```

| Command | What it does |
|---|---|
| `PING` | `PONG <version>` |
| `STATE` | JSON: status line, install progress window, panel sections, accounts, tracked apps (with expiry), GitHub/AltStore search state, windows |
| `WINDOWS` | JSON list of visible windows (number, title, class, frame, key, modal, panel) |
| `ALERT` | JSON of the current alert: texts, buttons, field values (`ERR no alert`) |
| `PANEL open\|close\|toggle` | Opens/closes the menu-bar panel (clicks the status item's button) |
| `SECTION accounts\|install\|settings open\|close` | The panel's disclosure sections |
| `EXPAND\|COLLAPSE account <appleID>` / `app <appleID/origBundleID>` / `apps` / `accounts` | Per-account and per-app rows |
| `DO <action> [args]` | Every panel button and prompt: `add-account`, `cancel-add-account`, `pick-ipa`, `pick-json`, `github-prompt`, `altstore-repo-prompt`, `search-github [q]`, `close-search-github`, `github-user <u>`, `search-altstore [q]`, `close-search-altstore`, `load-source <url>`, `add-source <url>`, `install-github <repo>`, `install-source <name>`, `open-ipa <path>`, `url <sidestep://…>`, `refresh <origBundleID> [udid] [appleID]`, `refresh-everywhere <origBundleID>`, `refresh-all`, `check-updates`, `self-update-check`, `token-prompt`, `anisette-prompt`, `debug-log`, `devmode-help <device> [manual\|rebooting]`, `trust-hint <appleID>` |
| `SET <field> <text>` | Set a field at once: `githubQuery`, `altStoreQuery`, `appleID`, `password`, `code`, `sourceURL`, or `alert` (the current alert's text field) |
| `TYPE <field> <text> [chars/s]` | Same, letter by letter (default 12/s), for video |
| `CLICK <button title>` | Clicks an AppKit button (alerts first, then the key window, then any window) |
| `CLOSE <window title>` | Closes a window |
| `SNAP panel\|alert\|<title>\|<window#> [path] [scale]` | PNG of a SideStep window, drawn by the app itself (no Screen Recording permission, nothing on screen disturbed). Title bar included. `scale` 2 gives a crisp 2x image on a 1x display. Default path `~/Library/Application Support/SideStep/debug-snaps/` |
| `DEMO alias "<real>" "<shown>"` / `DEMO clear` / `DEMO list` | Display-only name substitution (account names, device names, progress and status text) so screenshots never show real Apple IDs or devices |

## Driving the iPhone/iPad side (DEVICE)

While the debug token exists, every app SideStep installs or refreshes carries it
(`BeaconInjector.beaconDebugToken()`: `SIDESTEP_BEACON_TOKEN`, else the token file). Once
such an app is open and has Local Network access, its beacon dials the Mac on **TCP 51236**
and says `HELLO <token> <udid> <bundle> <version>`; SideStep keeps that connection
(`DeviceRelay` in DebugControl.swift) and forwards commands to it. Apps installed before the
token existed have no channel until they're refreshed. (`Provision --beacon-serve` uses the
same port, so it can't run while a token-configured SideStep is running.)

| Command | What it does |
|---|---|
| `DEVICES` | JSON list of connected beacons: udid, bundle, version, device name |
| `DEVICE <match> <command…>` | Forward one beacon command; `match` is `any` or part of a udid, bundle id or device name |

Beacon commands (`BeaconInject/beacon_inject.m`, `beaconCommandReply`):

| Command | What it does |
|---|---|
| `PING` / `STATE` | `PONG <version>` / JSON of the beacon's state |
| `PANEL [close]` | Opens (or closes) the Updater panel, as the two-corner gesture does |
| `MORE` | Opens the panel's "Install more apps…" sheet |
| `UI` | JSON: panel open?, update card status, and the top alert/sheet (title, message, actions, field) or app list (rows) |
| `PICK <title>` | Taps that action in the top alert or sheet ("Search AltStore", "Continue", "Done"…) |
| `TYPE <text>` / `SET <text>` | Types (12 letters/s) or sets the top alert's text field |
| `ROW <title>` | Taps that row in the top app list (starts the install) |
| `DONE` | Dismisses the top alert, sheet or list |
| `UPDATE` | Opens the panel and runs "Update app now" (note: at 100% the app quits itself) |
| `BEACON` | Sends one beacon now |
| `ALIAS <from>\|<to>` / `ALIAS clear` | Display-only name substitution on the device (panel text, lists, install messages) |
| `SNAP [path]` | PNG of the app's window, alerts and lists included (the keyboard is a separate system window and isn't). The Mac saves it and replies with JSON `{path,width,height}` |

```bash
regression/ssctl DEVICES
regression/ssctl DEVICE magnatune PANEL
regression/ssctl DEVICE magnatune SNAP ~/Desktop/updater.png
regression/ssctl DEVICE magnatune MORE
regression/ssctl DEVICE magnatune PICK "Search AltStore"
regression/ssctl DEVICE magnatune TYPE emulator
regression/ssctl DEVICE magnatune PICK Search
```

## Gotchas

- **Alerts.** SideStep opens NSAlerts with `runModal()` from main-queue work, which blocks the
  main *queue* until the alert closes. So commands don't use `DispatchQueue.main` or MainActor
  Tasks: they run as run-loop blocks registered for the default, modal-panel and
  event-tracking modes, which `runModal`'s loop services. Commands that open an alert reply
  `OK` first and open it 50 ms later; check with `ALERT`.
- **SwiftUI buttons** aren't NSButtons, so `CLICK` only reaches AppKit buttons (alerts, open
  panels). SwiftUI windows are driven through `DO` and `SET`/`TYPE` instead.
- The panel window opens 50% taller than its content (by design), so a panel snapshot has
  white space at the bottom.
- Testing a dev build without replacing /Applications/SideStep.app:
  `./bundle-app.sh /some/dir` (it bumps VERSION.txt: restore it), quit the installed
  SideStep, `open -n /some/dir/SideStep.app`. Don't run two SideSteps at once: they share
  state and devices.
- **Launching an app on the device without touching it:** `xcrun devicectl device process launch
  --terminate-existing --device <udid> <installed bundle id>` (the installed id is
  `com.sidestep.<name>.<team>`; `xcrun devicectl device info apps --device <udid>` lists them).
  Its beacon then dials in within a few seconds; check with `DEVICES`.
- An app keeps its debug channel until it is next installed or refreshed by a SideStep with no
  token, so a debug-token Mac leaves token-gated ports on the apps it touches.
- Verified 2026-10-29 on an iPhone 14 Pro Max (iOS 26): PANEL, MORE, PICK, TYPE, ROW list, DONE,
  UI and SNAP (1290×2796 PNGs, alerts and lists included).
