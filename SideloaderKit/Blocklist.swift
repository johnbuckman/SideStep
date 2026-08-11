// Anti-piracy blocklist. SideStep refuses to ADD known pirate sources or INSTALL
// exact known cracked files, and asks for CONFIRMATION before sideloading a known
// PAID App Store app (so a legitimate owner can still proceed — no false positives
// for people installing apps they actually own).
//
// The rules live in blocklist.json: it ships inside the app (offline fallback) and
// is refreshed from the repo at launch, so new pirate sources can be added without
// shipping a new build. See blocklist.json for the matching contract.
import Foundation
import CryptoKit

public struct Blocklist: Sendable {
    struct SourceRule: Sendable { let host: String; let pathContains: String?; let note: String }
    var sources: [SourceRule] = []
    var paidBundleIds: [String: String] = [:]     // real App Store bundle id -> app name
    var fileHashes: Set<String> = []              // ipaSha256 ∪ binarySha256 (all lowercased)

    // MARK: - load / refresh

    static let refreshURL = "https://raw.githubusercontent.com/johnbuckman/SideStep/main/blocklist.json"
    static let cachePath  = SideStepSupportDir + "/blocklist.json"
    nonisolated(unsafe) private static var _shared = Blocklist.load()
    public static var shared: Blocklist { _shared }

    /// Freshest available: downloaded cache → app-bundled fallback → empty (fail open,
    /// so a missing list never blocks a legitimate install).
    static func load() -> Blocklist {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: cachePath)), let b = parse(d) { return b }
        if let u = Bundle.main.url(forResource: "blocklist", withExtension: "json"),
           let d = try? Data(contentsOf: u), let b = parse(d) { return b }
        return Blocklist()
    }

    /// Pull the newest blocklist from the repo, cache it, and swap it in. Best-effort.
    public static func refresh() async {
        guard let u = URL(string: refreshURL),
              let (d, _) = try? await Net.api.data(from: u),
              let b = parse(d) else { return }
        try? FileManager.default.createDirectory(atPath: SideStepSupportDir, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: cachePath))
        _shared = b
    }

    static func parse(_ data: Data) -> Blocklist? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var b = Blocklist()
        for s in (o["sources"] as? [[String: Any]] ?? []) {
            guard let host = (s["host"] as? String)?.lowercased(), !host.isEmpty else { continue }
            b.sources.append(SourceRule(host: host,
                                        pathContains: (s["pathContains"] as? String)?.lowercased(),
                                        note: (s["note"] as? String) ?? ""))
        }
        for p in (o["paidBundleIds"] as? [[String: Any]] ?? []) {
            if let id = p["id"] as? String, !id.isEmpty { b.paidBundleIds[id] = (p["app"] as? String) ?? id }
        }
        for h in (o["ipaSha256"] as? [String] ?? []) + (o["binarySha256"] as? [String] ?? []) {
            b.fileHashes.insert(h.lowercased())
        }
        return b
    }

    // MARK: - source matching

    /// Non-nil (the rule's note) when this source URL is a known pirate source.
    /// Host-only rules match the whole host; host+pathContains rules match only that
    /// manifest path, so a host that also serves legitimate apps isn't over-blocked.
    public func blockedSource(_ urlString: String) -> String? {
        guard let (host, path) = Self.hostPath(urlString) else { return nil }
        for r in sources where host == r.host || host.hasSuffix("." + r.host) {
            if let pc = r.pathContains {
                if path.contains(pc) { return r.note.isEmpty ? "known pirate source" : r.note }
            } else {
                return r.note.isEmpty ? "known pirate source" : r.note
            }
        }
        return nil
    }

    static func hostPath(_ s: String) -> (host: String, path: String)? {
        let str = s.contains("://") ? s : "https://" + s          // tolerate a scheme-less URL
        guard let u = URLComponents(string: str), let h = u.host?.lowercased() else { return nil }
        let host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        let path = ((u.percentEncodedPath.removingPercentEncoding ?? u.path)).lowercased()  // decode %2B%2B → ++
        return (host, path)
    }

    // MARK: - install screening

    public enum Screen: Sendable {
        case allow
        case block(String)                              // hard refusal (zero-FP: source/hash)
        case warnPaid(app: String, bundleID: String)    // confirmation gate (owner may proceed)
    }

    /// Decide what to do with an app about to be installed. `appPath` is the unsigned
    /// input `.app`; `origin` is where it came from (a download/source URL or a file path).
    /// Screen the ORIGINAL app — call before SideStep rewrites its bundle id.
    public func screen(appPath: String, origin: String) -> Screen {
        // 1) Provenance: fetched straight from a blocklisted source → hard block.
        if let note = blockedSource(origin) {
            return .block("This app came from a source SideStep blocks — \(note).")
        }
        // 2) Exact known cracked file (zero false positives).
        if origin.hasSuffix(".ipa"), FileManager.default.fileExists(atPath: origin),
           let h = Self.sha256(ofFile: origin), fileHashes.contains(h) {
            return .block("This exact IPA is a known pirated app.")
        }
        if let exe = Self.mainExecutable(inApp: appPath), let h = Self.sha256(ofFile: exe), fileHashes.contains(h) {
            return .block("This app's binary is a known pirated build.")
        }
        // 3) A known PAID App Store app → confirm (a legitimate owner may proceed).
        let bid = Self.plistString("CFBundleIdentifier", appPath + "/Info.plist") ?? ""
        if let app = paidBundleIds[bid] { return .warnPaid(app: app, bundleID: bid) }
        return .allow
    }

    // MARK: - helpers

    static func plistString(_ key: String, _ plistPath: String) -> String? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let o = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any]
        else { return nil }
        return o[key] as? String
    }

    static func mainExecutable(inApp appPath: String) -> String? {
        guard let exe = plistString("CFBundleExecutable", appPath + "/Info.plist"), !exe.isEmpty else { return nil }
        let p = appPath + "/" + exe
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    static func sha256(ofFile path: String) -> String? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}
