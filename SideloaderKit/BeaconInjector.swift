// BeaconInjector — instruments an app bundle with the wireless self-updater before
// SideStep signs it: injects an LC_LOAD_DYLIB pointing at a bundled BeaconInject.dylib,
// drops the dylib + a per-install BeaconConfig.plist into the bundle, and merges the
// Info.plist keys the beacon needs. Pure Swift — no Python, no external tools.
//
// Best-effort: if the binary can't be patched (fat, no header padding), it logs and
// skips instrumentation rather than breaking an otherwise-good install.
import Foundation

public enum BeaconInjector {
    static let dylibName = "BeaconInject.dylib"
    static let bgTaskID  = "com.sidestep.beacon.refresh"

    /// Instrument `appDir` (a .app). Returns true if the beacon was injected.
    @discardableResult
    public static func instrument(appDir: URL, dylibSource: String, macIP: String, udid: String,
                                  bundleID: String, updateInterval: Int = 86400,
                                  foundVia: String = "", autoUpdates: Bool = false,
                                  log: (String) -> Void) -> Bool {
        let fm = FileManager.default
        let infoPlist = appDir.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoPlist) as? [String: Any],
              let exeName = info["CFBundleExecutable"] as? String else {
            log("beacon: no CFBundleExecutable — skipping instrumentation"); return false
        }
        let exe = appDir.appendingPathComponent(exeName)

        // 1) inject the load command
        do {
            try injectLoadCommand(binary: exe, dylibInstallName: "@executable_path/\(dylibName)")
        } catch {
            log("beacon: could not inject (\(error)) — skipping instrumentation"); return false
        }

        // 2) de-obfuscate the shipped data blob into a real dylib in the bundle.
        // (It ships XOR-0xA5'd so it isn't a Mach-O the macOS notary would scan.)
        let dylibDst = appDir.appendingPathComponent(dylibName)
        try? fm.removeItem(at: dylibDst)
        do {
            let blob = try Data(contentsOf: URL(fileURLWithPath: dylibSource))
            try Data(blob.map { $0 ^ 0xA5 }).write(to: dylibDst)
        } catch { log("beacon: dylib restore failed (\(error)) — skipping"); return false }

        // 3) per-install runtime config. beacon_version = the SideStep version that injected
        // this beacon, shown on the on-device diagnostics panel so you can tell at a glance
        // whether an app carries an up-to-date beacon (matches your current SideStep) or an
        // old one that needs a reinstall.
        // The GUI app's bundle carries the version; a headless CLI (Provision) doesn't, so
        // fall back to $SIDESTEP_VERSION for test installs.
        var sideStepVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if sideStepVersion.isEmpty { sideStepVersion = ProcessInfo.processInfo.environment["SIDESTEP_VERSION"] ?? "" }
        var cfg: [String: Any] = [
            "mac_ip": macIP, "udid": udid, "bundleid": bundleID,
            "port": 51234, "update_interval": updateInterval, "foreground_check": 1800,
            "found_via": foundVia, "auto_updates": autoUpdates ? 1 : 0,
            "beacon_version": sideStepVersion,
        ]
        // The on-device beacon debug/control channel (inbound port + outbound dial-out) is
        // OFF by default — release and GUI installs ship no listening port and no token. It's
        // enabled ONLY when this build/install sets SIDESTEP_BEACON_TOKEN (the regression
        // harness does; nothing else). Without the token key, the beacon's startControlConnection
        // / startDebugListener both no-op. This is the build flag that keeps the debug surface
        // out of normal installs.
        if let debugToken = ProcessInfo.processInfo.environment["SIDESTEP_BEACON_TOKEN"], !debugToken.isEmpty {
            cfg["debug_port"] = 51237
            cfg["debug_connect_port"] = 51236
            cfg["debug_token"] = debugToken
        }
        (cfg as NSDictionary).write(to: appDir.appendingPathComponent("BeaconConfig.plist"), atomically: true)

        // 4) merge the Info.plist keys the beacon needs
        mergeInfoPlist(infoPlist)
        log("beacon: instrumented (mac \(macIP), interval \(updateInterval)s)")
        return true
    }

    // MARK: - Info.plist merge

    private static func mergeInfoPlist(_ url: URL) {
        guard let d = NSMutableDictionary(contentsOf: url) else { return }
        if d["NSLocalNetworkUsageDescription"] == nil {
            d["NSLocalNetworkUsageDescription"] = "Keeps this app up to date by checking with your Mac over Wi-Fi."
        }
        var ids = (d["BGTaskSchedulerPermittedIdentifiers"] as? [String]) ?? []
        if !ids.contains(bgTaskID) { ids.append(bgTaskID) }
        d["BGTaskSchedulerPermittedIdentifiers"] = ids
        d.write(to: url, atomically: true)
    }

    // MARK: - Mach-O: append an LC_LOAD_DYLIB into the header padding

    enum InjectError: Error, CustomStringConvertible {
        case notMachO, fatBinary, noPadding
        var description: String {
            switch self {
            case .notMachO: return "not a 64-bit Mach-O"
            case .fatBinary: return "fat binary (thin arm64 expected)"
            case .noPadding: return "no header padding for a new load command"
            }
        }
    }

    private static func u32(_ d: Data, _ off: Int) -> UInt32 {
        UInt32(d[off]) | UInt32(d[off+1]) << 8 | UInt32(d[off+2]) << 16 | UInt32(d[off+3]) << 24
    }
    private static func putU32(_ d: inout Data, _ off: Int, _ v: UInt32) {
        d[off] = UInt8(v & 0xff); d[off+1] = UInt8((v >> 8) & 0xff)
        d[off+2] = UInt8((v >> 16) & 0xff); d[off+3] = UInt8((v >> 24) & 0xff)
    }

    static func injectLoadCommand(binary: URL, dylibInstallName: String) throws {
        var data = try Data(contentsOf: binary)
        guard data.count > 32 else { throw InjectError.notMachO }
        let magic = u32(data, 0)
        if magic == 0xcafe_babe || magic == 0xbeba_feca { throw InjectError.fatBinary }
        guard magic == 0xfeed_facf else { throw InjectError.notMachO }   // MH_MAGIC_64

        let LC_SEGMENT_64: UInt32 = 0x19, LC_LOAD_DYLIB: UInt32 = 0x0C
        let ncmds = Int(u32(data, 16)), sizeofcmds = Int(u32(data, 20))
        let hdrEnd = 32 + sizeofcmds

        // lowest non-zero section file offset = where the header padding ends
        var firstSection = Int.max
        var off = 32
        for _ in 0..<ncmds {
            let cmd = u32(data, off), cmdsize = Int(u32(data, off + 4))
            if cmd == LC_SEGMENT_64 {
                let nsects = Int(u32(data, off + 64))
                var so = off + 72
                for _ in 0..<nsects {
                    let sectOff = Int(u32(data, so + 48))
                    if sectOff != 0 { firstSection = min(firstSection, sectOff) }
                    so += 80
                }
            }
            off += cmdsize
        }
        if firstSection == Int.max { firstSection = hdrEnd }

        // build LC_LOAD_DYLIB
        var name = Array(dylibInstallName.utf8); name.append(0)
        let cmdsize = (24 + name.count + 7) & ~7
        var lc = Data(count: cmdsize)
        putU32(&lc, 0, LC_LOAD_DYLIB); putU32(&lc, 4, UInt32(cmdsize))
        putU32(&lc, 8, 24)            // name offset
        putU32(&lc, 12, 2)            // timestamp
        putU32(&lc, 16, 0x1_0000)     // current_version 1.0.0
        putU32(&lc, 20, 0x1_0000)     // compatibility_version 1.0.0
        for (i, b) in name.enumerated() { lc[24 + i] = b }

        guard firstSection - hdrEnd >= cmdsize else { throw InjectError.noPadding }

        for i in 0..<cmdsize { data[hdrEnd + i] = lc[i] }
        putU32(&data, 16, UInt32(ncmds + 1))
        putU32(&data, 20, UInt32(sizeofcmds + cmdsize))
        try data.write(to: binary)
    }
}
