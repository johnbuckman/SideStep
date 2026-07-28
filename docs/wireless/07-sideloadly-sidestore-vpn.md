# 7. How SideStore's VPN solves the exact wall we hit (Sideloadly clarification)

**Question investigated:** "I believe Sideloadly uses a VPN to work around the problems
we had with the beacon connecting back to the Mac."

**Short answer:** The VPN is real, but it belongs to **SideStore** (the on-device,
no-computer AltStore fork), not to Sideloadly, and its purpose is **not** "connecting
back to the Mac." It exists to let an **on-device app reach the device's *own*
`lockdownd` over loopback** — which is **exactly the sandbox block our beacon spike
proved** (file 03). So the research strongly *validates* our finding and reveals the
"real" solution we identified but didn't build.

## What each tool actually does

- **Sideloadly** is a **desktop** app (Windows/macOS), like AltServer. Its "Wi-Fi
  refresh" uses the classic **computer→device usbmux-over-Wi-Fi** path (requires "Show
  this iDevice when on Wi-Fi" and same network). That's the same transport family as our
  direct-IP work — **no VPN involved.**
- **SideStore** is an **on-device** app (a fork of AltStore that "doesn't require an
  AltServer"). It re-signs and installs apps **entirely on the device**, with no
  computer. To do that, an on-device component (**minimuxer**, a Rust reimplementation of
  the usbmux/lockdown client) must talk to the device's own `lockdownd`/
  `installation_proxy`. **But an app can't reach `lockdownd` directly** (our spike). So
  SideStore ships a VPN.

## Why the VPN

- The on-device VPN provides an **on-device loopback tunnel** so minimuxer can reach
  `lockdownd` (e.g. via a tunnel address that loops back to the device's own services).
  This is the loopback technique from **Jitterbug's "EM Proxy"** (a minimal WireGuard-based
  loopback VPN server), reused by SideStore.
- Crucially, using **WireGuard** avoids needing the special **Personal VPN entitlement**
  (`com.apple.developer.networking.vpn.api`), which a free/sideloaded app can't have — so
  "anyone can sideload it and still get loopback." SideStore's current profile is called
  **StosVPN** and "completely replaces WireGuard" as the shipping mechanism, but the role
  is identical.
- Net: **the VPN is how SideStore tricks iOS into letting the app talk to `lockdownd` to
  install/manage apps locally** — the precise problem that stopped our app-side
  install/relay idea dead.

## What this means for SideStep

- Our conclusion in file 03 is correct and now corroborated: **app→lockdownd is blocked**;
  the only ways around it are (a) do the install from the **Mac** (our OTA or direct-IP
  paths), or (b) build a **VPN-loopback + minimuxer** stack like SideStore to do it fully
  **on-device**.
- Building the SideStore-style stack is a large effort (essentially adopting minimuxer +
  a WireGuard loopback VPN + pairing-file handling). It would give a **fully on-device,
  computer-free** refresher — but it's a major project and is the reason SideStore is
  heavy.
- Because we already proved **OTA** works through the hostile mesh with far less
  machinery, **OTA is the better near-term wireless path for SideStep**. The
  VPN-loopback approach is the alternative "north star" if a completely computer-free,
  free-tier-capable refresher becomes a goal.

## Sources

- [SideStore repo — "doesn't require an AltServer"](https://github.com/SideStore/SideStore)
- [Jitterbug #77 — Single-Device Loopback using EM Proxy and WireGuard](https://github.com/osy/Jitterbug/issues/77)
- [SideStore docs — common issues (minimuxer/VPN connection)](https://docs.sidestore.io/docs/troubleshooting/common-issues)
- [SideStore #519 — "make sure Wireguard is enabled …"](https://github.com/SideStore/SideStore/issues/519)
- [Sideloadly FAQ (desktop Wi-Fi setup)](https://sideloadly.io/faq.html)
- [Auto-refresh / StosVPN overview](https://techybuff.com/refresh-sidestore-sideloaded-automode/)
