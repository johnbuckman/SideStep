# SideStep — the complete guide

This guide walks you through everything: what SideStep is, what you need, exactly
what to do on your Mac **and** on your iPhone/iPad, and — importantly — the real
benefits and limits so you know what you're getting into before you start.

---

## 1. What SideStep is (and how it works)

SideStep is a small **macOS menu-bar app** that installs iOS apps onto your own
iPhone or iPad **without the App Store and without a jailbreak**, using your own
Apple ID to sign them.

It works the way AltStore/AltServer do, but simpler and self-contained:

1. You sign in with an Apple ID (a free one is fine).
2. SideStep asks Apple for a free **development certificate** and a
   **provisioning profile** for your device — exactly what Xcode does for
   developers.
3. It **signs the app on your Mac** with that certificate.
4. It **installs the app onto your device** over the USB cable (the same channel
   Finder uses to sync).

The catch with free Apple IDs is that Apple only makes those profiles valid for
**7 days**. So SideStep also **re-signs and re-installs your apps automatically**
before they expire, as long as the app is running on your Mac and your device is
reachable.

**Everything happens from your Mac.** The iPhone/iPad has no special software on
it — it just receives the signed app. That also means the apps stay tied to *this*
Mac (it holds your logins and signing certificate).

---

## 2. What you need

- A **Mac** (macOS 14 or newer).
- An **iPhone or iPad**.
- A **USB/Lightning/USB-C cable** to connect them. (Wi-Fi is possible but
  unreliable on modern iOS — see §9.)
- An **Apple ID**. A **free** one works. You can create a fresh one at
  <https://icloud.com> — a dedicated "sideloading" Apple ID is recommended so you
  don't tie up your main account's developer slots.
- The app you want to install, as an **`.ipa` file** or an **AltStore-format
  source** (a URL or `.json` catalog that points at `.ipa` files).

---

## 3. Understand the limits FIRST (free vs paid)

This is the part people wish they'd read first.

**With a FREE Apple ID:**

| Limit | Value |
|---|---|
| Apps installed at once (per Apple ID) | **3** |
| How long an app stays valid before it must be re-signed | **7 days** |
| New App IDs you can register | ~**10 per 7 days** |
| Signing certificates | **1** |
| Entitlements | Limited — **no** push notifications, iCloud, app groups, associated domains, HealthKit, etc. |

- **3-app limit — but you can beat it with multiple Apple IDs.** Each free Apple
  ID keeps only 3 sideloaded apps installed at once. **SideStep lets you add as
  many Apple IDs as you like, and each one is completely independent — it gets its
  own 3 app slots and its own signing.** So 2 accounts = 6 apps, 3 accounts = 9,
  and so on. Since you can create extra free Apple IDs in seconds at
  <https://icloud.com>, adding accounts is the easy way to *greatly* increase how
  many apps you can install — SideStep just asks which account to use each time.
- **7-day expiry:** after 7 days an app "expires" and stops launching until it's
  re-signed. SideStep refreshes automatically (see §7), but the app must be
  refreshed *before* the 7 days are up, which means your Mac + device need to be
  together periodically.
- **Entitlement limits:** apps that need push notifications, iCloud sync, app
  groups, etc. **will not install or run** on a free account. Plain apps are fine.

**With a PAID Apple Developer account ($99/year):**

- Apps last **1 year** instead of 7 days.
- The app-count limit is effectively lifted.
- Full entitlements.

SideStep shows each account's type ("Free · 7 days" or "Paid · 1 year") and, for
free accounts, a live **`slots N/3`** indicator.

**If your Apple ID is in more than one team.** Some Apple IDs belong to both a
personal **free** team *and* a **paid** team (for example, a company you develop
for). When that's the case SideStep can't guess which one you want, so the
account row shows a **Team** menu with a "⚠ Choose a team" prompt. Pick the team
to sign with — the **free** team gives 7-day installs, a **paid** team gives
1-year. Your choice is remembered per account, and you can switch teams there at
any time. SideStep only ever adds *its own* certificate to a paid team; it never
revokes the certificates other developers on that team rely on.

---

## 4. Prepare your iPhone/iPad (do this once)

**a. Connect it to the Mac with a cable and unlock it.**

**b. Trust the computer.** The first time you connect, the device asks
"Trust This Computer?" — tap **Trust** and enter your passcode.

**c. Turn on Developer Mode** *(required on iOS/iPadOS 16 and later)*:

1. On the device: **Settings → Privacy & Security → Developer Mode**.
2. Toggle **Developer Mode** on.
3. The device restarts; after it reboots, confirm **Turn On**.

> Without Developer Mode, iOS 16+ will refuse to launch sideloaded apps — you'll
> see "Untrusted Developer" or the app just won't open. If you don't see a
> Developer Mode option, connect the device to the Mac once and it should appear.

**d. (Optional) Enable Wi-Fi sync** if you want to *try* refreshing without a
cable: with the device plugged in, open **Finder → [your device] → General →
"Show this iPhone/iPad when on Wi-Fi"**. (See §9 for why USB is still the reliable
path.)

---

## 5. Install SideStep on your Mac

1. Open the downloaded `.dmg` and drag **SideStep** into your **Applications**
   folder. The app is **signed with a Developer ID and notarized by Apple**, so it
   opens normally — you do *not* need the right-click → "Open" Gatekeeper
   workaround.
2. Launch it. SideStep is a **menu-bar app** — it doesn't appear in the Dock;
   look for the **crate icon in your menu bar** (top-right). Click it to open the
   panel. The panel grows and shrinks to fit its contents as you expand or collapse
   sections.

> **Requirements:** macOS 14 (Sonoma) or newer, Apple Silicon. This is still a
> **beta** — please report anything rough.

Optionally, in the panel's **Settings** section, enable **"Launch SideStep at
login"** so it's always running and can keep your apps refreshed.

---

## 6. Add your Apple IDs and install apps

**a. Add an account.** In the SideStep panel, under *Your Apple accounts*, click
**Add account** (or just fill the login box):

- Enter the Apple ID email + password.
- **Two-factor:** if the account has no Apple device signed into it (typical for a
  dedicated sideloading ID), tick **"Text me the code"** — Apple will SMS the code
  to the phone number on the account. Enter the code.
- On success the account appears with its type badge and slot count.
- **If the Apple ID is in more than one team**, the row shows a **Team** menu
  ("⚠ Choose a team") — pick free (7-day) or paid (1-year) before installing.

You can add **as many Apple IDs as you like**, and **each account has its own
separate install limit** — a free account is capped at 3 apps *individually*, so
2 accounts let you install 6, 3 accounts 9, and so on. When you install, SideStep
asks which account to use; pick one that still has a free slot.

> Your password is only used to talk to Apple and is stored in the macOS Keychain
> so the app can refresh unattended. It is never written in plain text.

**b. Install an app** (device connected + unlocked):

- **Source URL** — paste an AltStore-format source URL, click **Load**, then
  **Install** next to the app you want; or
- **Install from .json…** — pick a local AltStore-format catalog file; or
- **Install from .ipa…** — pick a single `.ipa` (or `.app`) file.

If you have more than one account or more than one device connected, SideStep
asks **which account** and **which device** to use.

**c. Trust the developer on the device.** The first app you install from a given
Apple ID needs a one-time trust:

- On the device: **Settings → General → VPN & Device Management** →
  under *Developer App*, tap your Apple ID → **Trust**.

Now open the app from your Home Screen. 🎉

---

## 7. Keeping apps alive (the 7-day thing)

Free-signed apps expire after 7 days. SideStep keeps them alive **by itself** —
there's no separate background program:

- SideStep **launches at login by default** (you can turn that off in Settings),
  so it's always in the menu bar keeping your apps alive.
- It re-signs and reinstalls an app once it passes **~70% of its 7-day window**
  (about 2 days before expiry). It pushes the update **the moment your device is
  reachable over USB or WiFi** — and near expiry it re-checks **every 5 minutes**,
  installing as soon as the device is awake/unlocked and on the network.
- There's also a **Refresh all apps now** button, and a per-app **Refresh**.

**Practical rule of thumb:** plug your device into this Mac every few days (before
the 7-day clock runs out) and your apps keep working. If a device is away from
this Mac for more than 7 days, its apps will expire until you reconnect.

---

## 8. Managing your apps (the menu-bar panel)

Under each Apple account you'll see its installed apps, and for each one:

- **which device** it's on and **when it expires** ("expires in N days", red if
  expired);
- a **Refresh** button — re-sign + reinstall that one app now;
- a **–** button — **uninstall** it from the device *and delete its App ID*, which
  **frees up a slot** so you can install something else.

Each free account shows **`slots N/3`**. Hit the limit? Remove an app (or add
another Apple ID) to make room.

---

## 9. Benefits

- **Free** — no paid developer account required.
- **No jailbreak** — uses Apple's official developer signing.
- **Your own signing** — apps are signed with *your* Apple ID, not a shared
  certificate that can get revoked out from under you.
- **Multiple accounts = many more apps** — add as many Apple IDs as you want and
  each adds its own 3 app slots, so your total capacity scales with the number of
  accounts. Push to several devices from one place, too.
- **Self-contained** — one menu-bar app; no server, no Docker, no companion app on
  the device.
- **Automatic upkeep** — handles the 7-day refresh for you.
- **Legitimate apps only** — SideStep refuses known pirate sources and cracked App
  Store apps, so it stays clean; it's built for open-source and self-published apps.

---

## 10. Limits & gotchas (read this)

- **3 apps per free Apple ID; 7-day expiry; ~10 App IDs/week; 1 certificate.**
  These are Apple's limits, not SideStep's. Add more Apple IDs for more slots.
- **Entitlements:** free accounts can't grant push notifications, iCloud, app
  groups, associated domains, etc. Apps needing them won't work — use a paid
  account for those.
- **Developer Mode is mandatory** on iOS 16+ (see §4c).
- **It's tied to this Mac.** Your logins, Keychain password, and signing
  certificate live on the Mac that installed the apps. A different Mac can't
  refresh them.
- **Wi-Fi refresh** needs the device **paired, on the same Wi-Fi network, and
  unlocked** — installs won't run against a *locked* device. That's exactly why,
  once an app is near expiry, SideStep re-checks **every 5 minutes** and pushes
  the moment the device is reachable and unlocked (so a device you pick up now and
  then will stay signed). Enable Wi-Fi sync (§4d) to allow it. **USB is still the
  most reliable** — a quick plug-in always refreshes everything that's due.
- **Rotating certificates:** if the saved certificate is ever lost or revoked,
  SideStep issues a new one; because a free account has only one certificate, the
  next refresh re-signs your apps onto the new one (they may briefly need that
  refresh to keep working).

---

## 11. Troubleshooting

- **"Untrusted Developer" / app won't open** → you skipped **Trust** (§6c) or
  **Developer Mode** (§4c).
- **Sign-in says "incorrect password" but it's right** → make sure you're using
  the right Apple ID; if the account has 2FA and no Apple device, use **"Text me
  the code."**
- **No 2FA code arrives** → tick **"Text me the code"** so it's sent by SMS to the
  phone number on the account (email does *not* receive 2FA codes).
- **"No device connected"** → plug in over USB, unlock the device, and make sure
  you tapped **Trust This Computer**.
- **Install fails at the last step** → confirm the device is unlocked and Developer
  Mode is on; try a different cable/port.
- **App expired** → open SideStep (or plug in) and hit **Refresh**; enable
  launch-at-login so it happens automatically.
- **"Maximum number of certificates"** → SideStep handles this by reusing/rotating
  your one free certificate; if it persists, remove an app to free things up.
- **Hit the 3-app limit** → remove an app (frees the slot) or add another Apple ID.

---

## 12. How it works under the hood (for the curious)

- **Login & provisioning** use Apple's developer services (the same APIs Xcode
  uses), including the "anisette" anti-abuse data generated locally on your Mac.
- **Signing** uses **zsign**, which produces a modern **SHA-256 CodeDirectory** —
  the format iOS 16–26 require (the older `ldid` used by some tools produces a
  SHA-1 signature that newer iOS rejects).
- **Installation** goes over the lockdown/`usbmux` protocol via a small bundled
  **libimobiledevice** helper — the same channel Finder uses. Everything ships
  inside the app; no Python or external tools are required.
- One **certificate is reused per account** (persisted locally), so re-signing one
  app doesn't invalidate your others.

---

## Credits & license

SideStep is built on **AltSign** from the **AltStore** / **SideStore** projects
(© Riley Testut and contributors), licensed **AGPL-3.0**, and is itself licensed
**AGPL-3.0**. The signer is **zsign** by zhlynn (**MIT**). See `LICENSE`.
