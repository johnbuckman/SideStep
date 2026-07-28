# SideStep — Wireless install & refresh research

This directory documents a deep investigation (2026-07-12) into **installing and
refreshing sideloaded iOS apps over the network instead of USB**, conducted end to
end against real iOS 26 hardware on a real (hostile) home mesh network.

It captures what works, what doesn't, every gotcha we hit, the tools built, and the
strategic conclusions about distribution and scale. Read the numbered files in
order for the full story, or jump to what you need.

> **New here (human or AI)?** Start with [`../AI-BOOTSTRAP.md`](../AI-BOOTSTRAP.md) for a
> fast orientation to the whole SideStep project, then come back for the wireless detail.

## TL;DR

- **USB install/refresh is the reliable floor** and is required for the free-Apple-ID
  tier no matter what (Apple ties over-the-air install to *paid* distribution signing).
- **Three wireless mechanisms** were investigated, forming a reliability ladder:
  1. **Direct-IP install** (lockdown/AFC by IP, bypassing mDNS) — works on cooperative
     networks, free-tier compatible, but **fragile** (an Eero mesh actively reset it).
  2. **Beacon discovery** (device UDP-pings the Mac) — **works through the mesh**,
     gives zero-scan, DHCP-proof discovery. But an on-device app **cannot** reach its
     own `lockdownd`, which kills app-driven install/relay over plain sockets.
  3. **OTA install** (`itms-services://` + a free trusted-HTTPS host) — **the robust
     wireless path**; proven end-to-end *through* the hostile mesh. Requires a **paid
     account + Ad-Hoc distribution signing**, and one user tap.
- The recommended wireless UX is a **QR-code "refresh portal"**: the Mac hosts a web
  page listing every managed app with one-tap OTA install links; SideStep shows a QR
  that opens it. It is expiry-proof (unlike a companion app, which itself expires).
- **Scaling:** the "100 devices" limit is an **Ad-Hoc** (central paid account) property,
  not an iOS or free-ID property. Decentralize the account (each user signs with their
  own free or paid Apple ID) and there is **no central device cap**. Free = 7-day + USB;
  each user's own paid ($99) account = 1-year + optional OTA. Beyond that, scale means a
  reviewable app on TestFlight/App Store.

## Files

| File | Contents |
|---|---|
| [01-problem-and-signing-models.md](01-problem-and-signing-models.md) | The 7-day problem; free vs paid signing; what USB actually provides |
| [02-direct-ip-install.md](02-direct-ip-install.md) | Install by IP bypassing mDNS; libimobiledevice patch; TLS/lock/mesh gotchas |
| [03-beacon-discovery.md](03-beacon-discovery.md) | UDP beacon; device→Mac works; the app-can't-reach-lockdownd spike |
| [04-ota-install.md](04-ota-install.md) | `itms-services` OTA; local-ip.co DNS+cert; Ad-Hoc requirement; codesign gotcha |
| [05-architecture-and-ux.md](05-architecture-and-ux.md) | Reliability ladder; QR portal; short-name redirect; no-USB flow; expiry edge cases |
| [06-distribution-and-scaling.md](06-distribution-and-scaling.md) | Device caps, per-user accounts, TestFlight/App Store/Enterprise, the trade-off tables |
| [07-sideloadly-sidestore-vpn.md](07-sideloadly-sidestore-vpn.md) | How SideStore's VPN solves the exact loopback block we found; Sideloadly clarification |
| [08-tools-and-reproduction.md](08-tools-and-reproduction.md) | Every tool/script built, how to rebuild and reproduce |

## Test hardware & environment (for reproducibility)

- **Mac:** Apple Silicon, macOS 26, IP `192.168.4.217` on the LAN.
- **"officepad":** iPad Pro 11" (`iPad14,3`), **iOS 26.5.2**, UDID `00008112-000A706A0107401E`
  (originally named "Gill ipad (2)", renamed Officepad during testing).
- **Other devices seen:** iPhone 14 Pro Max (`iPhone15,3`, iOS 26.5.2, UDID `00008120-…`),
  iPhone 13 Pro Max (iOS 26.3.1), iPad mini 1 (iOS 9.3.5).
- **Network:** **Eero mesh**, handing out a **/22** (`192.168.4.0/22`, mask `0xfffffc00`,
  spanning `.4`–`.7`). Multicast/mDNS does not reliably propagate; inbound dynamic
  high-port TCP to devices is actively reset; **but** outbound HTTPS and public-name→
  private-IP DNS both work.
- **Paid team:** `XLS3XF57J8` (Decent Espresso LLC / Vid Tadel).
