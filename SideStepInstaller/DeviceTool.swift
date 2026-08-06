//
//  DeviceTool — device checks for the wizard, run through SideStep's OWN libimobile-
//  device helpers (installed at <SideStep.app>/Contents/Helpers/idevice/). The
//  installer bundles none of this itself — SideStep is installed first, so its tools
//  are on disk by the time the device steps run. Mirrors SideloaderKit's parsing.
//

import Foundation

struct DeviceTool {
    let toolsDir: URL   // <SideStep.app>/Contents/Helpers/idevice

    init(sideStepApp: URL) {
        toolsDir = sideStepApp.appendingPathComponent("Contents/Helpers/idevice")
    }

    private func run(_ tool: String, _ args: [String]) -> String? {
        let exe = toolsDir.appendingPathComponent(tool)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { return nil }
        let p = Process(); p.executableURL = exe; p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    /// Connected devices as (udid, name, conn). An UNTRUSTED device reports its UDID as
    /// the name (the lockdown handshake failed), which the trust step keys off.
    func connectedDevices() -> [(udid: String, name: String, conn: String)] {
        guard let out = run("idevicehelper", ["list"]) else { return [] }
        func isUDID(_ s: String) -> Bool {
            s.allSatisfy { $0.isHexDigit || $0 == "-" } && (s.count == 40 || (s.count == 25 && s.contains("-")))
        }
        var seen = Set<String>()
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard let u = parts.first, isUDID(u), !seen.contains(u) else { return nil }
            seen.insert(u)
            let name = parts.count > 1 && !parts[1].isEmpty ? parts[1] : u
            let conn = parts.count > 2 ? parts[2] : "usb"
            return (u, name, conn)
        }
    }

    enum DevMode { case enabled, disabled, unsupported, unknown }

    func developerMode(_ udid: String) -> DevMode {
        guard let out = run("idevicedevmodectl", ["-u", udid, "list"]) else { return .unknown }
        for line in out.split(separator: "\n") where line.contains(udid) {
            let l = line.lowercased()
            if l.contains("enabled") { return .enabled }
            if l.contains("disabled") { return .disabled }
            if l.contains("unsupported") || l.contains("not supported") { return .unsupported }
        }
        if out.lowercased().contains("unsupported") { return .unsupported }
        return .unknown
    }

    @discardableResult
    func revealDeveloperMode(_ udid: String) -> Bool { run("idevicedevmodectl", ["-u", udid, "reveal"]) != nil }

    enum DevModeEnable { case enabled, rebooting, needsManual, unknown }

    /// `arm` returns immediately after asking iOS to reboot into Developer Mode.
    /// Succeeds only on an unlocked, trusted, passcode-free device.
    func tryEnableDeveloperMode(_ udid: String) -> DevModeEnable {
        guard let out = run("idevicedevmodectl", ["-u", udid, "arm"]) else { return .unknown }
        let l = out.lowercased()
        if l.contains("already enabled") || l.contains("successfully enabled") { return .enabled }
        if l.contains("armed") || l.contains("will reboot") || l.contains("waiting for reboot") { return .rebooting }
        if l.contains("passcode") || l.contains("on the device itself") { return .needsManual }
        return .unknown
    }

    static let developerModeHelp =
        "On the device, open Settings ▸ Privacy & Security ▸ scroll to the bottom ▸ Developer Mode ▸ turn it On. " +
        "The device restarts; after it reboots, unlock it and tap “Turn On” to confirm. (Requires iOS/iPadOS 16 or later.)"
}
