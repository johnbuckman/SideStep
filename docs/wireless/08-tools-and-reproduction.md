# 8. Tools built & how to reproduce

The **device/lockdown C tools are committed in [`Helpers/`](../../Helpers)** (they take
`<udid>`/`<ip>` as args — no hardcoded secrets; the compiled binaries are gitignored).
The **beacon iOS app** and the **Mac-side servers** lived in the session scratchpad (not
committed — the beacon hardcodes a test Mac IP and the servers carry the throwaway signed
IPA + published cert). This file records what each one is so they can be rebuilt or
productionized. Note the C tools link a **patched libimobiledevice** (`idevice_new_network`,
below) that must be built before they compile.

## Device / lockdown tooling (C, link libimobiledevice) — in `Helpers/`

| Tool | Purpose |
|---|---|
| `idevice_ipinstall.c` | Install an `.ipa` to `<udid>` **by IP** — lockdown handshake → AFC upload to `PublicStaging` → `instproxy_install`. Uses `idevice_new_network`. |
| `idevice_ipprobe.c` | Probe `<udid> <ip>`: `REACHABLE/UNREACHABLE` + `UNLOCKED/LOCKED` (via AFC directory read) + device name. The lock-state + identity primitive for the sweeper. |
| `sweep.sh` | Netmask-aware unicast scan of the local subnet(s) for `:62078` (reads the real mask via Python `ipaddress`, so it covers a /22), then identifies each host with `idevice_ipprobe`. DHCP- & mesh-proof discovery. |
| `idevice_setwifi.c` | Read/set wireless-lockdown `EnableWifiConnections` over USB (`lockdownd_set_value`), so SideStep enables Wi-Fi connectivity itself during the first cabled install. Verified `0→1`. |
| `idevice_netinstall.c` | Earlier variant: force transport `net`/`usb`/`both` via `idevice_new_with_options` lookup flags. Used to prove the USB path and that usbmux hides a network device while on USB. |

### The libimobiledevice patch (`idevice_new_network`)
Current libimobiledevice master requires **libtatsu** (a newer dep). A **debug** build
was made under `scratchpad/imd-debug/prefix` (deps: libplist, libimobiledevice-glue,
libusbmuxd, **libtatsu**; built with MacPorts `glibtoolize`/`autoreconf` at
`/opt/local/bin`, OpenSSL `/opt/homebrew/opt/openssl@3`, `--enable-debug` to get the SSL
logs). The patch adds:

```c
idevice_error_t idevice_new_network(idevice_t *device, const char *udid, const char *ip) {
    // malloc a struct idevice_private; udid=strdup; mux_id=0; version=0;
    // conn_type = CONNECTION_NETWORK; conn_data = sockaddr_in for <ip>; return SUCCESS.
}
```

To productionize: fold `idevice_new_network` into the **bundled** libimobiledevice dylib
so the shipped tools link it (the debug-prefix build was only for the spike). Note the
product's signing uses **zsign**, not codesign.

## Beacon (iOS app) — `scratchpad/beacon/`

- `main.swift` — UIKit app; on launch sends a UDP datagram to the Mac every second
  (`NWConnection`, unicast), shows a live counter, and (extended version) TCP-probes
  `127.0.0.1:62078`, self-IP:62078, and `127.0.0.1:27015` to test loopback→lockdownd
  reachability (all `pending` = blocked).
- `Info.plist` — has `NSLocalNetworkUsageDescription` (required for the LAN prompt).
- Built with `xcrun -sdk iphoneos swiftc -target arm64-apple-ios15.0`, bundled into
  `Beacon.app`, signed (dev cert + paid wildcard provisioning), packaged `Beacon.ipa`,
  installed over USB.

## Mac-side servers — `scratchpad/`

| Script | Purpose |
|---|---|
| `udplisten.py` | UDP listener on `:51234`; logs `BEACON FROM <ip> …`. Proves device→Mac reachability + learns the device IP. |
| `httpsserve.py` | HTTPS server on `:8443` serving `localhttps/` with the GlobalSign fullchain — the OTA host. |
| `localhttps/` | `index.html` (itms-services link), `manifest.plist`, `OtaTest.ipa`, `fullchain.pem` (leaf + GlobalSign G3 intermediate), `server.key`, `adhoc2.entitlements`. |
| `sign_ota.sh` | Re-sign OtaTest with the distribution cert + Ad-Hoc entitlements and repackage the IPA. |

### Reproducing the OTA host
1. `curl -sL https://local-ip.co/cert/server.pem -o server.pem` and `…/server.key`.
2. Fetch the correct intermediate via the leaf's AIA
   (`http://secure.globalsign.com/cacert/gsgccr6alphasslca2025.crt`), DER→PEM, and
   `cat server.pem intermediate.pem > fullchain.pem`.
3. Serve `index.html` + `manifest.plist` + IPA over HTTPS on `<dashed-mac-ip>.my.local-ip.co`.
4. Sign the IPA **Ad-Hoc** (`get-task-allow=false`) with a distribution cert whose key is
   native to the Mac.
5. Open `https://<dashed-mac-ip>.my.local-ip.co:8443/` in Safari on the device; tap Install.

## Signing assets used

- Regenerated distribution identity: **`Apple Distribution: Decent Espresso LLC (XLS3XF57J8)`**
  (SHA-1 `5F52E5A7…`), key generated natively on this Mac via Keychain Access CSR.
- Wildcard Ad-Hoc profile: `~/Desktop/SideStep_AdHoc_2.mobileprovision`
  (`XLS3XF57J8.*`, `get-task-allow=false`, all devices).
- Paid dev wildcard (for the beacon): `~/iwish/dist/paid-XLS3XF57J8.mobileprovision`.

## Background servers still running after the session

`httpsserve.py` (:8443), `udplisten.py` (:51234) — stop with `pkill -f httpsserve.py`
and `pkill -f udplisten.py` when done.
