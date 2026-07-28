# Device helper (bundled libimobiledevice)

`idevice/` contains a small, self-contained device tool that SideStep uses to
list connected devices and install/uninstall apps over USB — so the app needs
**no Python / pymobiledevice3** or any external tooling at runtime.

- `idevicehelper` — a ~130-line program (source: [`idevicehelper.c`](idevicehelper.c))
  that does `list` / `install <udid> <ipa>` / `uninstall <udid> <bundleid>` via
  AFC + `installation_proxy`.
- the relocatable arm64 dylibs it needs (`@rpath`, signed), so the whole thing
  runs from inside the `.app`.

## Rebuild from source

```
./build-idevice.sh        # clones + builds libimobiledevice (arm64) and stages ./idevice/
```

Needs autotools + pkg-config (e.g. MacPorts) and an arm64 OpenSSL
(e.g. `brew install openssl@3`).

## Bundled components & licenses

| Component | License |
|---|---|
| [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice), [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd) | LGPL-2.1+ |
| [libplist](https://github.com/libimobiledevice/libplist) | LGPL-2.1+ |
| [libimobiledevice-glue](https://github.com/libimobiledevice/libimobiledevice-glue) | LGPL-3.0+ |
| OpenSSL (`libssl`, `libcrypto`) | Apache-2.0 |
| `idevicehelper` (this repo) | AGPL-3.0 |

All are GPL/AGPL-compatible; the LGPL libraries are dynamically linked and can be
rebuilt/relinked via `build-idevice.sh`.
