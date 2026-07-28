# Current State — OTA / QR install, progress, and device registration

**Purpose:** this is the *bootstrap* document. Read it and you should be able to
resume work on SideStep's wireless-install features with no other context.
Last substantive update: **2026-07-28**.

## ✅ Beta 0.1 (2026-07-28) — what shipped since 0.2 alpha

- **Wireless install over Wi-Fi is proven end-to-end**, including on an Eero mesh.
  Root cause of the old failures was the missing **heartbeat**
  (`com.apple.mobile.heartbeat`): the host must answer the device's Marco/Polo pings
  or iOS resets the AFC upload connection over Wi-Fi (AFC error 34 / RST). Direct-IP
  install (`idevice_new_network` against stock libimobiledevice, pair record by UDID)
  works with zero discovery. **instproxy must use a NULL status callback** — a non-nil
  callback made it async, returned 0 immediately, dropped the connection, and
  false-reported "INSTALL OK". Upload streams `PROGRESS sent total` for a live %/ETA.
- **Self-updating beacon loop.** `BeaconInject` dylib (runtime-configured via
  `BeaconConfig.plist`) is injected at install time (LC_LOAD_DYLIB into header
  padding; shipped as an XOR data blob in `Contents/Resources/` so notarization never
  scans an iOS binary). App beacons "unlocked+ready"; the Mac's native
  `BeaconListener` (`_sidestep._udp` Bonjour + UDP :51234) re-signs and pushes the
  newest build back over Wi-Fi. iOS defers the running app's bundle swap until it
  exits, so the beacon self-`exit(0)`s ~2s after upload.
- **UX:** consolidated install into one "Do you want to install X?" dialog that lists
  devices labeled USB/Wi-Fi + Developer Mode; Developer Mode detect + `arm` (no
  passcode) + reveal + honest popup; one-time trust hint per Apple ID; Debug Log
  window; crash-safe `/tmp/sidestep.log`.
- **Two launch/robustness fixes worth remembering:** (1) the app died right after
  init on some Macs with **EXIT=141 = SIGPIPE** — the diagnostics `Pipe` was a local
  var that dealloc'd, closing the read end; fixed with `signal(SIGPIPE, SIG_IGN)` +
  retaining the pipe. (2) The `.ipa` file chooser greyed until "navigate away and
  back" because a menu-bar (`.accessory`) app can't make a modal `NSOpenPanel` the key
  window; fixed by switching to `.regular` activation policy while the panel is open.

Older detail below is retained for the OTA/QR/registration mechanics.

---


Companions: [AI-BOOTSTRAP.md](AI-BOOTSTRAP.md) (project orientation),
[TLDR.md](TLDR.md) (who can sideload what), [wireless/](wireless/) (the original
research). This file supersedes them where they disagree about *current* state.

---

## 1. Orientation

- **Repo:** `github.com/johnbuckman/SideStep` (AGPL-3.0). Git root is
  `~/altstore-fork/AltSign-SS`, branch **`isl-main`**, remote **`sidestep`**.
- **Installed app:** `/Applications/AI Apps/SideStep.app` (menu-bar, `LSUIElement`).
- **Build the app:** `./bundle-app.sh` (in repo) or `~/altstore-fork/rebuild-app.sh`
  (John's local variant, **not** in the repo — it also bundles `Helpers/idevice`
  and sets the `.ipa` file association).
- **CLI for testing:** `Provision` — `swift build --product Provision`, binary at
  `$(swift build --show-bin-path)/Provision`.

### ⚠️ Build gotcha that will waste your time
`swift build` sometimes **recompiles a changed module but skips relinking the
executable**, leaving a stale binary. Symptom: your edits "don't take" and you
debug the wrong code for an hour. Both build scripts now `rm -f` the binary
first to force a relink. If you build by hand, do the same:
```bash
rm -f "$(swift build --show-bin-path)/Provision"; swift build --product Provision
```

### ⚠️ Port 8443 gotcha
The OTA host listens on **:8443**. If the **menu-bar app is running with a host
active**, it owns that port and your CLI test will silently hit *the app's* old
code instead of your new binary. Always check first:
```bash
lsof -nP -iTCP:8443 -sTCP:LISTEN
```

---

## 2. How the QR / OTA install works

The device installs over the air via `itms-services://`; the Mac is the server.

1. `IPAInspector.inspect(path)` classifies the IPA → `signer` (development /
   adhoc / enterprise / appstore) and `otaCapable` (= adhoc || enterprise).
2. If OTA-capable, the app offers **"Show QR code (over the air)"**; otherwise it
   falls back to USB and spells out the Developer-Mode + Trust steps.
3. `OTAHost.start(ipaPath:info:)` stages the IPA + `manifest.plist` + an install
   page, and serves them over **trusted HTTPS**.
4. The device scans the QR, opens the page, taps Install; `installd` fetches
   `manifest.plist` then the `.ipa`, and installs.

### Trusted HTTPS without owning a domain — local-ip.co
`<dashed-lan-ip>.my.local-ip.co` resolves publicly to that (private) IP, and
local-ip.co publishes a real wildcard cert for `*.my.local-ip.co`. So the Mac can
present a **publicly-trusted** cert for its LAN address, which `itms-services`
requires. Two hard-won details:

- Their `chain.pem` is a **stale/mismatched Sectigo chain** — ignore it. Fetch the
  correct **GlobalSign** intermediate via the leaf's AIA URL.
- You must present the **full chain**: use
  `sec_identity_create_with_certificates(id, [interCert])`. Plain
  `sec_identity_create()` sends leaf-only and iOS rejects it.
- **Fetch the intermediate over HTTPS, not HTTP.** The AIA URL is `http://`, but
  the bundled app enforces **App Transport Security** and silently fails the load
  (`NSURLError -1022`). This exact bug made "Show QR code" do *nothing*. The CLI
  isn't ATS-restricted, which is why it worked there and not in the app.

---

## 3. Ad-hoc signing recipe (what makes an IPA OTA-installable)

OTA requires **ad-hoc distribution** signing: `get-task-allow=false`, an
`Apple Distribution` cert, and a profile listing the **exact device UDIDs**.
Development-signed IPAs are *silently dropped* by `installd` over OTA.

Assets in use:
- Cert: **`Apple Distribution: Decent Espresso LLC (XLS3XF57J8)`**, SHA-1
  `5F52E5A765CC6B226BE3098A4B3176CC67070C8A`, in John's login keychain.
- Profile: **`~/Desktop/SideStep_AdHoc_2.mobileprovision`** — wildcard App ID
  `XLS3XF57J8.*` (so it signs *any* bundle id), valid to **2027-07-12**,
  currently **4 devices**.

Re-sign recipe (no private-key export needed — `codesign` uses the keychain):
```bash
# 1. entitlements with the CONCRETE bundle id (not the wildcard)
#    application-identifier = XLS3XF57J8.<bundleid>, get-task-allow = false,
#    com.apple.developer.team-identifier = XLS3XF57J8, keychain-access-groups
# 2. swap in the ad-hoc profile, drop the old signature
cp SideStep_AdHoc_2.mobileprovision "$APP/embedded.mobileprovision"
rm -rf "$APP/_CodeSignature"
# 3. sign NESTED code first (dylibs/.so, then .framework bundles), then the app
find "$APP" \( -name '*.dylib' -o -name '*.so' \) -type f -exec codesign -f -s "$ID" --timestamp=none {} \;
find "$APP" -name '*.framework' -type d -exec codesign -f -s "$ID" --timestamp=none {} \;
codesign -f -s "$ID" --timestamp=none --entitlements ent.plist "$APP"
# 4. verify, then zip Payload/ into the .ipa
codesign --verify --strict --verbose=2 "$APP"
```
Verify OTA-capability with `Provision --inspect foo.ipa` → expect
`signer=adhoc  otaCapable=true`.

### zsign on Linux (for the server-side signer)
Built on **decentespresso.com** at **`/home/decent/bin/zsign`** — zsign **v1.0.8**
(commit `09486af`), **statically linked** against a locally built **OpenSSL 3.0.15**
(`~/openssl-3`), because the box only has OpenSSL 1.0.2 and zsign v1.0.8 needs
`openssl/provider.h` (OpenSSL 3). Source trees in `~/zsign-build`.
- **Gotcha:** that static OpenSSL 3 has the **legacy provider inactive**, so it
  **cannot read a macOS-Keychain-exported `.p12`** (legacy SHA1/RC2). Use **PEM
  key + cert** (or a modern AES p12). Convert once:
  `openssl pkcs12 -legacy -in kc.p12 -nocerts -nodes -out key.pem` /
  `... -clcerts -nokeys -out cert.pem`.
- Flags: `zsign -k key.pem -c cert.pem -m profile.mobileprovision -o out.ipa in.ipa`.

---

## 4. Developer Mode — the finding that changes the UX story

**Ad-hoc apps DO require Developer Mode** on iOS 16+ (verified on hardware
2026-07-13). `get-task-allow=false` does *not* exempt them: the exemption is by
**distribution channel**, and only **App Store / TestFlight / Enterprise in-house
(`ProvisionsAllDevices`) / MDM** are exempt. Ad-hoc (a device-list profile) counts
as a development/testing channel.

Consequence: the OTA flow is **cable-free, no Trust dance, 1-year profile** — but
**not zero-touch**. First run on each device needs
`Settings ▸ Privacy & Security ▸ Developer Mode` → on → restart. All user-facing
copy (app dialog, QR window, device install page, and `/beta`) says so; earlier
"nothing else to do to your device" wording was wrong and has been corrected.

---

## 5. Install progress ("Level 1") — implemented

We cannot get a completion callback from `itms-services` (iOS gives the page
nothing). Instead the **server** watches the install, because the device pulls
from us.

`OTAHost` tracks stages and exposes them:
- `manifest.plist` fetched → **confirmed** (the user tapped Install and confirmed)
- `.ipa` GET started → **downloading**
- `.ipa` fully sent → **downloaded**

`GET /status` → `{"stage":"…","sent":N,"total":N}`.

- **Device page** polls `/status` and updates its text, plus a delayed
  "didn't appear? Developer Mode / registered" hint.
- **Mac QR window** shows a **determinate progress bar** with MB and %. To make
  that possible the IPA is streamed in **512 KB chunks** (`sendIPAChunk`), each
  reporting cumulative bytes via `OTAHost.onProgress` → `OTAProgress` (an
  `ObservableObject`) → `QRView`.
- Verified: chunked streaming is **byte-identical** to the original (install
  integrity intact) and produces ~54 incremental updates on a 27 MB IPA.

**Not implemented ("Level 2"):** a definitive "Installed ✓" requires the *app*
to ping home on first launch. Download-complete ≠ install-success (it can still
fail on profile/Developer-Mode/space). Failures are only inferred via timeout.

---

## 6. Device registration over Wi-Fi (UDID capture) — implemented

A web page **cannot** read the UDID via JavaScript. The working technique is a
signed **`.mobileconfig` "Profile Service"**: the device installs a small profile
and iOS **POSTs back a CMS-signed plist** containing UDID / PRODUCT / VERSION /
DEVICE_NAME. (Same technique Diawi / UDID.tech use; also implemented in
`/d/lib/otabeta.tcl` server-side.)

In the app: **"Register a device over Wi-Fi…"** →
`OTAHost.startUDIDCapture()` → QR/link → device installs profile → the Mac window
shows **"Device registered ✓"** with the UDID and a Copy button.

Endpoints in `.udid` mode:
| path | purpose |
|---|---|
| `GET /` | enroll page with the Register button |
| `GET /enroll.mobileconfig` | the Profile Service payload, **signed with the local-ip.co cert** so iOS shows "Verified" (falls back to unsigned) |
| `POST /enrolled` | parse the CMS body → `onUDID(udid, product, version)` |
| `GET /status` | `{"udid":"…"}` |

Implementation notes:
- `handle()` was rewritten into `readRequest()` which accumulates until headers +
  full `Content-Length` body — needed because the callback POSTs a multi-KB body
  (the old code only read the request line).
- `OTAHost.Mode` (`.install` / `.udid`) selects `serveInstall` vs `serveUDID`.
- Callback parsing shells out to
  `openssl smime -verify -noverify -inform der`, then scrapes the plist keys.
- **iOS friction:** it is *not* one-tap. Safari downloads the profile, then the
  user must go to **Settings ▸ Profile Downloaded ▸ Install** (passcode).
- Getting the UDID is only step 1 — you still must **register it with Apple**,
  **regenerate the ad-hoc profile**, and **re-sign** the apps.

---

## 7. File map

| file | role |
|---|---|
| `SideloaderKit/OTAHost.swift` | the whole HTTPS host: TLS via local-ip.co, install mode (manifest/ipa/status, chunked streaming, progress), UDID mode (Profile Service, callback parse) |
| `SideloaderKit/IPAInspector.swift` | classify an IPA → signer + `otaCapable` |
| `InstallerApp/App.swift` | `AppModel` (openIPA chooser, `startOTA`, `captureUDID`), `OTAProgress`, `QRView`, `UDIDCapture`, `UDIDCaptureView`, `AppDelegate` (.ipa open) |
| `Provision/main.swift` | CLI: `--inspect <ipa>`, `--ota <ipa>`, `--getudid`, plus auth/install modes |
| `bundle-app.sh` | build + bundle the app (forces relink) |

---

## 8. Test recipes (no device needed)

```bash
cd ~/altstore-fork/AltSign-SS
rm -f "$(swift build --show-bin-path)/Provision"; swift build --product Provision
BIN="$(swift build --show-bin-path)/Provision"
lsof -nP -iTCP:8443 -sTCP:LISTEN     # make sure the app isn't squatting

# ---- install + progress ----
"$BIN" --ota ~/Desktop/iWish-adhoc.ipa &      # prints the https URL
curl -s "$BASE/status"                        # {"stage":"waiting",...}
curl -s "$BASE/manifest.plist" >/dev/null     # -> "confirmed"
curl -s "$BASE/iWish.ipa" -o /tmp/dl.ipa      # -> "downloading" -> "downloaded"
cmp /tmp/dl.ipa ~/Desktop/iWish-adhoc.ipa     # MUST be identical

# ---- UDID capture (simulate the device callback) ----
"$BIN" --getudid &
curl -s "$BASE/enroll.mobileconfig" -o /tmp/mc.bin
openssl smime -verify -noverify -inform der -in /tmp/mc.bin | grep 'Profile Service'
# fake a signed device-attributes plist and POST it:
openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 1 -nodes -subj "/CN=dev"
openssl smime -sign -signer c.pem -inkey k.pem -nodetach -outform der -in attrs.plist -out cb.der
curl -s -X POST --data-binary @cb.der -H "Content-Type: application/pkcs7-signature" "$BASE/enrolled"
# host logs: ">>> UDID CAPTURED: <udid> product=… version=…"
```

---

## 9. Open items / where to pick up

1. **Magnatune won't install on John's iPhone** — error *"cannot be installed
   because its integrity could not be verified."* Diagnosed: the IPA is fine
   (valid signature, real iOS arm64 app, min iOS 17, byte-identical over the
   wire). Cause: **the iPhone's UDID is not in the 4-device ad-hoc profile.**
   Fix: capture the UDID (§6) → register with Apple → regenerate
   `SideStep AdHoc 2` → re-sign Magnatune / de1app / iWish → reinstall.
   Test IPAs live on the Desktop: `Magnatune-v0.1.0-adhoc.ipa`,
   `de1app-adhoc.ipa`, `iWish-adhoc.ipa`.
2. **Level 2 install confirmation** — add a first-launch ping from the app so the
   page/window can say "Installed ✓" instead of only "downloaded".
3. **Mirror progress + UDID capture into `/beta`** (`/d/lib/otabeta.tcl`,
   uncommitted, separate CVS repo — *not* part of this git repo). Caveat:
   NaviServer's `ns_returnfile` gives no send-completion hook, so `/beta` can do
   waiting → confirmed → downloading but not a reliable "downloaded".
4. **SideStore-based Wi-Fi auto-refresh** — the plan to beat the "an app can't
   reach its own lockdownd" barrier (StosVPN fake-iTunes + pairing file +
   jkcoxson/idevice). **On hold** by John's decision; see the memory note
   `sidestore_wifi_refresh_plan`.
5. **100-device ad-hoc cap** is the ceiling for this whole channel. Beyond it:
   TestFlight/App Store (needs App Review → the Flutter app), not a multi-account
   ad-hoc farm (circumvention → revocation risk).

---

## 10. Things that are NOT in this repo

- `~/altstore-fork/rebuild-app.sh` — John's local build script.
- `/d/lib/otabeta.tcl` + `/d/lib/otabeta_README.md` — the decentespresso.com
  `/beta` web installer (NaviServer/Tcl, CVS, uncommitted).
- `/home/decent/bin/zsign` on decentespresso.com (see §3).
- The signing cert (keychain) and `~/Desktop/SideStep_AdHoc_2.mobileprovision`.
