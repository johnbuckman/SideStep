import Foundation

/// What we can learn from an `.ipa` (or `.app`) about how it can be installed.
public struct IPAInfo: Sendable {
    public var appName: String
    public var bundleID: String
    public var version: String
    /// The provisioning profile's signing category.
    public enum Signer: String, Sendable { case development, adhoc, enterprise, appstore, unsigned }
    public var signer: Signer
    /// True iff this IPA can be installed **over the air** (QR / `itms-services`): a
    /// distribution profile with `get-task-allow == false`. Development-signed IPAs are
    /// silently rejected by installd over OTA, so those must go over USB.
    public var otaCapable: Bool { signer == .adhoc || signer == .enterprise }
}

public enum IPAInspector {

    /// Inspect an `.ipa` or unpacked `.app`. Reads `Info.plist` + `embedded.mobileprovision`
    /// from `Payload/<App>.app`. Never throws — returns a best-effort `IPAInfo`.
    public static func inspect(_ path: String) -> IPAInfo {
        let fm = FileManager.default
        var appDir: String? = nil
        var scratch: String? = nil

        if path.hasSuffix(".app") {
            appDir = path
        } else {
            // unzip just the Payload into a temp dir and find the .app
            let tmp = NSTemporaryDirectory() + "sidestep-inspect-" + UUID().uuidString
            try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            scratch = tmp
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-q", "-o", path, "Payload/*", "-d", tmp]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            let payload = tmp + "/Payload"
            if let entries = try? fm.contentsOfDirectory(atPath: payload) {
                appDir = entries.first { $0.hasSuffix(".app") }.map { payload + "/" + $0 }
            }
        }
        defer { if let s = scratch { try? fm.removeItem(atPath: s) } }

        guard let app = appDir else {
            return IPAInfo(appName: (path as NSString).lastPathComponent, bundleID: "", version: "", signer: .unsigned)
        }

        // Info.plist
        let info = (try? Data(contentsOf: URL(fileURLWithPath: app + "/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] } ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let bid  = (info["CFBundleIdentifier"] as? String) ?? ""
        let ver  = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? ""

        // embedded.mobileprovision → the signing category
        let signer = signerCategory(app + "/embedded.mobileprovision")
        return IPAInfo(appName: name, bundleID: bid, version: ver, signer: signer)
    }

    /// Read the provisioning profile (a CMS blob with an embedded plist) and classify it.
    private static func signerCategory(_ provPath: String) -> IPAInfo.Signer {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: provPath)),
              let plist = embeddedPlist(raw) else { return .unsigned }

        let ent = plist["Entitlements"] as? [String: Any] ?? [:]
        let getTaskAllow = (ent["get-task-allow"] as? Bool) ?? false
        let provisionsAll = (plist["ProvisionsAllDevices"] as? Bool) ?? false
        let hasDevices = (plist["ProvisionedDevices"] as? [Any])?.isEmpty == false

        if getTaskAllow { return .development }          // dev profile → USB only
        if provisionsAll { return .enterprise }          // in-house → OTA
        if hasDevices { return .adhoc }                  // ad-hoc (registered UDIDs) → OTA
        return .appstore                                 // no devices, no get-task-allow → App Store dist
    }

    /// The .mobileprovision is DER CMS wrapping a plist; the plist is plaintext XML inside.
    /// Slice out `<plist …>…</plist>` rather than decoding CMS (no external deps).
    private static func embeddedPlist(_ data: Data) -> [String: Any]? {
        guard let open = data.range(of: Data("<plist".utf8)),
              let close = data.range(of: Data("</plist>".utf8)) else { return nil }
        let slice = data.subdata(in: open.lowerBound ..< close.upperBound)
        return (try? PropertyListSerialization.propertyList(from: slice, options: [], format: nil)) as? [String: Any]
    }
}
