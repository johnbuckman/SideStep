# 1. The problem & the signing models

## The 7-day (and 1-year) problem

Sideloaded apps are signed with a **provisioning profile** that expires:

- **Free Apple ID** → development signing, **7-day** validity, **3 apps** at once per
  Apple ID, ~10 App IDs/week, 1 certificate, limited entitlements (no push, iCloud,
  app groups, …).
- **Paid Apple Developer account ($99/yr)** → **1-year** validity, effectively no
  app-count limit, full entitlements.

When the profile expires the app stops launching until it is **re-signed and
re-installed**. Today SideStep does this over **USB**. The whole investigation was
about doing the re-sign+reinstall (and even the first install) **over the network**.

## What USB actually provides (so we know what to replace)

1. **Device pairing / trust** — the "Trust This Computer?" handshake that creates the
   lockdown **pair record** (host cert/key + escrow bag) used for all lockdown ops.
2. **The device's UDID** — needed to build a provisioning profile (dev or ad-hoc must
   name the device).
3. **`EnableWifiConnections`** — the Finder "Show this iPhone when on Wi-Fi" toggle,
   which is what makes the device *listen* on the lockdown port over Wi-Fi.
4. **The install transport** — AFC upload + `installation_proxy` over lockdown/usbmux.

Each of these has (or needs) a wireless replacement; see the other files. Key up-front
facts we established:

- **`EnableWifiConnections` is required** for any lockdown-over-Wi-Fi path (with it off,
  the device closes port 62078 on Wi-Fi). **But SideStep can set it itself over USB**
  during the first cabled install via `lockdownd_set_value` (verified: flips `0→1`), so
  the user never touches Finder. It even persists across device reboots.
- The pair record lives at `/var/db/lockdown/<UDID>.plist` and is read **by UDID**, so a
  direct-IP connection can authenticate without the device being "discovered."

## Two fundamentally different signing models (this is the crux of scaling)

The device-count limits people worry about depend entirely on **whose Apple account
does the signing**:

### A. Decentralized — each user signs with *their own* Apple ID (the AltStore model)
- Each user registers only **their own** device under **their own** account.
- **You (the distributor) have no central device cap.** Scales to unlimited users.
- Free ID → 7-day validity, USB only (development signing can't do OTA — see file 04).
- Each user's own **paid** ($99) ID → **1-year** validity, and can even do OTA for their
  own device — but that's **$99/user/year**.

### B. Centralized — you sign everything under *one* paid account (Ad-Hoc)
- **You** register every device's UDID under your account.
- This is where the **100-devices-per-year** cap comes from (it's an Ad-Hoc property).
- Enables the cable-free **OTA** path (see file 04), $99 total.

**The fundamental tension:** the cable-free OTA path (model B) requires paid Ad-Hoc
*distribution* signing and is capped at 100 devices. The unlimited path (model A) is
free/per-user but **cannot use OTA** (free = development signing, which iOS refuses to
install over the air) — so it stays on USB. You cannot have *both* "unlimited devices"
and "cable-free central install" within Apple's rules. See file 06 for the full
scaling analysis.
