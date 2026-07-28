# 4. OTA install (`itms-services://`) — the robust wireless path

**This is the mechanism that actually worked end-to-end through the hostile Eero mesh.**
The device *pulls* a signed IPA from the Mac over trusted HTTPS and iOS installs it
itself. Nothing connects *into* the device; no lockdownd, no AFC, no inbound ports —
so all the mesh/DHCP/mDNS problems evaporate.

## How OTA install works

iOS supports over-the-air app install via a URL scheme used by MDM / ad-hoc / enterprise
beta distribution:

```
itms-services://?action=download-manifest&url=https://HOST/manifest.plist
```

The `manifest.plist` names the app (`bundle-identifier`, `bundle-version`, `title`) and
the **HTTPS URL of the `.ipa`**. iOS fetches the manifest, downloads the IPA, and installs
it. Requirements:
- The manifest **and** IPA must be served over **HTTPS with a cert iOS trusts** (no
  self-signed / no bare-IP cert).
- The IPA must be signed for **OTA distribution** — see "Ad-Hoc requirement" below.

## The trusted-HTTPS-on-a-LAN problem, solved for free

itms-services needs a **trusted** HTTPS cert for a **hostname** (not a bare IP), and the
Mac is a private LAN box behind NAT. Solution: free "LAN HTTPS" services that provide
**both** a public wildcard-DNS mapping *and* a publicly-trusted wildcard cert:

- **`local-ip.co`** (used here): `192-168-4-217.my.local-ip.co` resolves to
  `192.168.4.217` for anyone, and it publishes a **GlobalSign** wildcard cert (+ key)
  for `*.my.local-ip.co`. GlobalSign is trusted by iOS out of the box.
- `traefik.me`, `sslip.io`, `nip.io` are similar (sslip/nip are DNS-only, no cert).

The published private key is fine here: iOS only checks the cert is validly signed by a
trusted CA for the hostname; the payload is a code-signed IPA anyway. For production you
could **self-host** the same pattern (your own wildcard DNS + wildcard cert) so it
doesn't depend on a third party's uptime.

### Gotcha: local-ip.co ships a **mismatched chain**
Their leaf is issued by `GlobalSign GCC R6 AlphaSSL CA 2025`, but their published
`chain.pem` is a **stale Sectigo chain** — so `curl`/iOS get
`unable to get local issuer certificate`. Fix: fetch the *correct* intermediate from the
leaf's **AIA** (`http://secure.globalsign.com/cacert/gsgccr6alphasslca2025.crt`), convert
DER→PEM, and serve `fullchain = leaf + that intermediate`. It chains to **GlobalSign Root
R6** (trusted). After that, system-trust `curl` returns 200.

## Proven flow (through the Eero mesh, on officepad / iOS 26.5.2)

1. Mac serves `index.html` (with the itms-services link) + `manifest.plist` + `OtaTest.ipa`
   over HTTPS on `https://192-168-4-217.my.local-ip.co:8443/` using the GlobalSign fullchain.
2. Safari on the device loads the page — **no cert warning** (so DNS-rebinding did **not**
   block the public-name→private-IP resolution, and the cert is trusted).
3. Tap the link → iOS shows the native **"… would like to install 'SideStep OTA Test'"**
   prompt → **Install**.
4. Server log shows the device fetch `manifest.plist`, `HEAD` then full `GET` of the IPA
   over HTTPS, then install. **App lands on the home screen and runs.**

Everything the mesh blocked (inbound to the device) is avoided; everything it allows
(the device's outbound HTTPS) is used.

## The Ad-Hoc requirement (this is the real limitation)

**OTA/itms-services requires a *distribution* profile — Ad-Hoc or Enterprise — signed
with `get-task-allow=false`.** A **development** profile (free-account or paid dev) is
**silently dropped by `installd`**: we watched a dev-signed IPA download over and over
(each failed install retried) and never install. Re-signed Ad-Hoc, it installed on the
first try.

Consequence: **OTA is a paid-account feature.** The free-Apple-ID tier can only do
development signing → USB only (file 06).

## The codesign / keychain gotcha (and why it won't affect production)

Signing the Ad-Hoc IPA with the pre-existing `Apple Distribution: Vid Tadel` cert failed
with `errSecInternalComponent` + `unable to build chain to self-signed root` — even on a
throwaway file, while the *development* cert signed fine. We ruled out:
- missing intermediate (dist cert's AKI matched the present WWDR G3's SKI),
- chain validity (`security verify-cert` succeeded — it fetches intermediates via AIA;
  codesign only uses the keychain),
- key ACL / partition list (`security set-key-partition-list …` — no change),
- expired duplicate WWDR certs (deleted the 2023 one — no change).

→ The **imported private key for that one identity was corrupt** for codesign on this
Mac. **Fix:** regenerate a fresh Apple Distribution cert whose **key is generated
natively on this Mac** (CSR via Keychain Access), producing
`Apple Distribution: Decent Espresso LLC (XLS3XF57J8)` (SHA-1 `5F52E5A7…`) + a new
**wildcard** Ad-Hoc profile (`XLS3XF57J8.*`). It signed immediately.

**Important:** the *shipped product* signs via **zsign** (`native_bridge_zsign_sign`),
not macOS `codesign`, so this keychain bug would not affect SideStep in production. It
only bit the manual spike.

## Practical notes

- The Ad-Hoc profile must include the device UDID (wildcard *App ID* still needs explicit
  *devices*). Selecting **"Select All"** devices avoids guessing which portal name maps to
  the target — portal device names are the registration-time names and don't update on
  rename.
- Likely (verify on a *clean* device): Ad-Hoc distribution installs run **without** the
  "Trust Developer" step or **Developer Mode** — those are development-signing
  requirements. Our OtaTest ran with no such step, but officepad was already set up from
  prior dev installs, so that's not a clean proof.
- Port `:8443` worked for both manifest and IPA. If some iOS build is picky, fall back to
  `:443` (needs a privileged listener). See file 05.
