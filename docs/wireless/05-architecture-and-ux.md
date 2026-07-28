# 5. Architecture, UX, and the expiry edge cases

## The reliability ladder

No single wireless mechanism works everywhere, and that's fine — pick the best rung the
network + account allow, and always fall back to USB. **Nobody is ever stuck**, because
USB is 100% and is required for the first pairing/install anyway.

| Path | Reliability | Needs | Cable-free? | Notes |
|---|---|---|---|---|
| **USB** | 100% | cable | ❌ | The floor; first install; free-tier |
| **OTA** (itms-services + local-ip.co) | High | paid account, one user tap | ✅ | Worked through the hostile mesh (outbound HTTPS) |
| **Direct-Wi-Fi** (lockdown/AFC by IP) | Situational | awake+unlocked, network not isolating high ports | ✅ silent | Free-tier compatible but fragile (died on Eero) |

Honest promise to users: *"plug in once; after that it usually keeps itself fresh over
the air, and if your network is difficult, a quick plug-in always fixes it."* That
under-promises and over-delivers — the same position AltStore lives with.

## The recommended wireless UX: a QR "refresh portal" (not a companion app)

A **web page on the Mac** that lists every managed app for the device, each with a
one-tap `itms-services://` install/refresh link.

Why a web page beats a **companion app**:
- A companion app has a chicken-and-egg flaw — *it* also expires and needs refreshing.
- A web page **never expires**; it works even when **every app on the device is dead**,
  because it's served from the Mac and Safari is always available.
- Tapping a link installs a fresh IPA **over** the expired one (same bundle ID) — the
  dead app never has to run to be resurrected.
- We already built ~90% of it (the HTTPS server + a one-app page).

### Bootstrapping the URL (solving DHCP + typing)
The portal URL contains the Mac's DHCP-dynamic IP, so:
- **Primary: a QR code** in SideStep's menu-bar panel encoding the *current* URL. Point
  the iPad camera at it → Safari opens the portal. Zero typing, always current.
- **Typeable fallback: a bare-IP redirect.** Run a tiny HTTP listener on the Mac so the
  user types just `192.168.4.217` → `302` → the trusted HTTPS portal. Binding `:80`
  (and serving the portal on `:443` to drop the `:8443`) needs a **one-time privileged
  helper** (LaunchDaemon); without it, fall back to `IP:8080`.
- **`.local` (Bonjour) is shortest but unreliable *on a mesh*** — same multicast problem
  as device discovery. Best-effort only.
- **A vanity/public short domain can't do it**: the redirect target is the user's own
  dynamic *private* LAN IP, which only *their* Mac knows — so the redirector must live on
  the Mac (reached by LAN IP or `.local`).

### Nice touches
- **Per-device listing:** the beacon (file 03) tells the Mac "device X is at IP Y," so
  when IP Y loads the portal, the Mac can show *that device's* apps. Fallback: list all
  apps grouped by device.
- **Sign on demand:** re-sign a fresh Ad-Hoc IPA when a row is tapped (a few seconds via
  zsign), so the served copy is always current.

## Can we drop USB *entirely*? (paid tier: yes)

USB provides pairing, UDID capture, `EnableWifiConnections`, and the install transport.
For the **OTA path** you don't need pairing, `EnableWifiConnections`, or the lockdown
transport at all — only the **UDID** (to build the Ad-Hoc profile). And you can capture
the UDID **wirelessly**:

- Serve a **signed `.mobileconfig`** enrollment profile (the Diawi / InstallOnAir
  technique). The user installs it (a few Settings taps); the device **POSTs its UDID**
  back to the Mac. The Mac registers the UDID (dev-portal API) → generates the Ad-Hoc
  profile → signs → serves the OTA link.

So the fully cable-free **paid** flow is: scan QR → "Add this device" (install profile,
UDID captured) → tap Install → done; later, scan QR → tap to refresh. **No cable ever.**
(Verify the "no Trust step / no Developer Mode" claim on a clean device before promising
it.) The **free** tier still needs USB (development signing + Developer Mode).

## The "runs longer than 7 days without closing" edge case

- **A running app is *not* killed when its cert expires.** The signature is checked at
  **launch**, not continuously — so an already-running app keeps working past 7 days.
  Expiry only bites at the **next launch after it's been terminated**.
- iOS won't keep an app resident for 7 days anyway (background suspension + **jetsam** +
  reboots) — it gets relaunched well within the window, and the relaunch triggers a
  refresh.
- Belt-and-suspenders for injected/own apps: fire refresh on **`applicationDidBecomeActive`**
  (every foreground, not just cold launch) **plus** a lightweight in-app timer while in
  the foreground; and refresh **early** (~70%, ~2 days before expiry) to widen the window.
- The one genuinely unavoidable case (true for *any* signing tool): **an app that fully
  expires before it refreshed can't be launched, so it can't trigger its own refresh.**
  → This is exactly where the **QR portal wins**: it's not the dead app doing the work —
  the portal (from the Mac, via Safari) OTA-installs a fresh copy **over** the expired
  one, no cable, no need for the corpse to run.

## Getting code into apps you didn't write (for the auto/beacon behavior)

Two ways to make an arbitrary app ping the Mac / trigger a refresh:

- **Sign-time dylib injection** (per-app, seamless): build a tiny `beacon.dylib` with a
  `__attribute__((constructor))`, copy it into the bundle, add an `LC_LOAD_DYLIB` load
  command to the main Mach-O (`insert_dylib`/`optool`), add `NSLocalNetworkUsageDescription`
  to Info.plist, then re-sign the whole bundle — which SideStep already does. Because the
  whole bundle is signed by **one** cert, the injected dylib is not a nested-signature
  mismatch (that's the `0xe8008001` bug AltStore hits by leaving nested dylibs
  mis-signed — SideStep's uniform zsign re-sign is *why* injection is clean here). The
  constructor runs before `UIApplication` exists, so defer `openURL(itms-services…)` until
  `UIApplicationDidBecomeActiveNotification`. Caveats: a local-network permission prompt;
  the install trigger interrupts; rare anti-tamper apps notice the extra dylib;
  FairPlay-encrypted App Store binaries can't be injected (sideload IPAs are decrypted).
- **The QR portal** (no injection, simpler, more robust): recommended as the backbone;
  treat injection as an opt-in nicety for the "just works when I open my app" experience.
