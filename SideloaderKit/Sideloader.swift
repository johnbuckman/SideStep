// SideloaderKit — shared provisioning + signing + install pipeline for SideStep.
// Handles: local Anisette, session persistence, keychain password (for unattended
// refresh), AltStore-format source parsing + IPA download, the provision→sign→
// install flow for any app, tracking installed apps, and a 7-day refresh.
import Foundation
import AltSign
import SwiftBridge
import CryptoKit
import Security

public enum SideErr: LocalizedError {
    case fail(String)
    /// The device couldn't be registered because this Apple ID hit Apple's per-type
    /// device-registration limit. Carries the account it failed on, the device's name,
    /// and the other Apple IDs already in SideStep (so the UI can offer a retry).
    case deviceLimit(appleID: String, deviceName: String, bundleID: String, others: [String])
    public var errorDescription: String? {
        switch self {
        case .fail(let s): return s
        case .deviceLimit(let aid, let dev, _, _):
            return "Apple won’t register \(dev.isEmpty ? "this device" : "“\(dev)”") on \(aid) — it has reached Apple’s limit on how many devices this Apple ID can register. Install with a different Apple ID to add more devices."
        }
    }
}

public func cont<T>(_ body: (@escaping (T?, Error?) -> Void) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        body { value, error in
            if let value { c.resume(returning: value) }
            else { c.resume(throwing: error ?? SideErr.fail("nil result")) }
        }
    }
}

let SideStepSupportDir = NSString(string: "~/Library/Application Support/SideStep").expandingTildeInPath

// MARK: - Local Anisette (AOSKit / AuthKit)

public enum Anisette {
    private static let loaded: Bool = {
        dlopen("/System/Library/PrivateFrameworks/AOSKit.framework/AOSKit", RTLD_NOW)
        dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW)
        return true
    }()
    private static func akDevice() -> AnyObject? {
        guard let cls = NSClassFromString("AKDevice") else { return nil }
        return (cls as AnyObject).perform(NSSelectorFromString("currentDevice"))?.takeUnretainedValue()
    }
    private static func otpHeaders() -> [String: String]? {
        guard let cls = NSClassFromString("AOSUtilities") else { return nil }
        let r = (cls as AnyObject).perform(NSSelectorFromString("retrieveOTPHeadersForDSID:"), with: "-2")
        return r?.takeUnretainedValue() as? [String: String]
    }
    private static func sha256Upper(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02X", $0) }.joined()
    }
    public static func fresh() -> ALTAnisetteData? {
        _ = loaded
        guard let otp = otpHeaders(), let md = otp["X-Apple-MD"], let mdm = otp["X-Apple-MD-M"],
              let dev = akDevice() else { return nil }
        let desc = (dev.value(forKey: "serverFriendlyDescription") as? String) ?? "<Mac> <macOS;26.2;25C56> <com.apple.AuthKit/1>"
        let devUUID = (dev.value(forKey: "uniqueDeviceIdentifier") as? String) ?? UUID().uuidString
        let luUUID = (dev.value(forKey: "localUserUUID") as? String) ?? UUID().uuidString
        let serial = (dev.value(forKey: "serialNumber") as? String) ?? "0"
        return ALTAnisetteData(machineID: mdm, oneTimePassword: md, localUserID: sha256Upper(luUUID),
                               routingInfo: 17106176, deviceUniqueIdentifier: devUUID, deviceSerialNumber: serial,
                               deviceDescription: desc, date: Date(), locale: .current, timeZone: .current)
    }
}

// MARK: - Account persistence (multiple Apple IDs; each free ID = 3 app slots)

/// One Apple developer team the account belongs to. type: 3=free, 1/2=paid.
public struct TeamInfo: Codable, Identifiable, Sendable, Hashable {
    public var id: String       // ALTTeam.identifier
    public var name: String
    public var type: Int
    public init(id: String, name: String, type: Int) { self.id = id; self.name = name; self.type = type }
    public var isPaid: Bool { type == 1 || type == 2 }
    public var label: String { "\(name) — \(isPaid ? "1 year" : "7 days")" }
}

public struct AccountRecord: Codable, Identifiable, Sendable {
    public var dsid, authToken, appleID, identifier, firstName, lastName: String
    public var teamType: Int = -1      // chosen team's ALTTeamType raw: 3=free, 1/2=paid
    public var teamName: String = ""   // chosen team's name
    public var teamID: String = ""     // chosen team's identifier (durable selection key)
    public var teams: [TeamInfo] = []  // every team this Apple ID belongs to
    public var id: String { appleID }
    public var teamChosen: Bool { !teamID.isEmpty }
    public var needsTeamChoice: Bool { teams.count > 1 && teamID.isEmpty }
    public var displayName: String {
        let n = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? appleID : "\(n) (\(appleID))"
    }
    public var isPaid: Bool { teamType == 1 || teamType == 2 }
    public var validity: String {
        switch teamType {
        case 3: return "Free · apps expire after 7 days"
        case 1, 2: return "Paid · apps last 1 year"
        default: return ""
        }
    }
}

extension AccountRecord {
    // Lenient decode so records written before teamType/teamName still load.
    enum CodingKeys: String, CodingKey { case dsid, authToken, appleID, identifier, firstName, lastName, teamType, teamName, teamID, teams }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dsid = try c.decode(String.self, forKey: .dsid)
        authToken = try c.decode(String.self, forKey: .authToken)
        appleID = try c.decode(String.self, forKey: .appleID)
        identifier = try c.decode(String.self, forKey: .identifier)
        firstName = try c.decode(String.self, forKey: .firstName)
        lastName = try c.decode(String.self, forKey: .lastName)
        teamType = try c.decodeIfPresent(Int.self, forKey: .teamType) ?? -1
        teamName = try c.decodeIfPresent(String.self, forKey: .teamName) ?? ""
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID) ?? ""
        teams = try c.decodeIfPresent([TeamInfo].self, forKey: .teams) ?? []
    }
}

public enum AccountStore {
    static let path = SideStepSupportDir + "/accounts.json"
    public static func records() -> [AccountRecord] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let list = try? JSONDecoder().decode([AccountRecord].self, from: d) else { return [] }
        return list
    }
    static func write(_ list: [AccountRecord]) {
        try? FileManager.default.createDirectory(atPath: SideStepSupportDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: URL(fileURLWithPath: path)) }
    }
    public static func add(account: ALTAccount, session: ALTAppleAPISession) {
        var list = records().filter { $0.appleID != account.appleID }
        list.append(AccountRecord(dsid: session.dsid, authToken: session.authToken, appleID: account.appleID,
                                  identifier: account.identifier, firstName: account.firstName, lastName: account.lastName))
        write(list)
    }
    public static func remove(_ appleID: String) {
        write(records().filter { $0.appleID != appleID })
        Keychain.clear(appleID)
        CertStore.clear(appleID)
    }
    /// Record every team an Apple ID belongs to. Keeps an existing valid choice; auto-picks
    /// when there's exactly one team; leaves the choice empty (so the UI prompts) when there
    /// are several and none has been chosen yet.
    public static func setTeams(_ appleID: String, _ teams: [TeamInfo]) {
        var list = records()
        guard let i = list.firstIndex(where: { $0.appleID == appleID }) else { return }
        list[i].teams = teams
        if let sel = teams.first(where: { $0.id == list[i].teamID }) {
            list[i].teamType = sel.type; list[i].teamName = sel.name          // refresh label
        } else if teams.count == 1, let only = teams.first {
            list[i].teamID = only.id; list[i].teamType = only.type; list[i].teamName = only.name
        } else {
            list[i].teamID = ""; list[i].teamType = -1; list[i].teamName = ""  // ambiguous → prompt
        }
        write(list)
    }
    /// Explicit user choice of which team to sign with.
    public static func chooseTeam(_ appleID: String, id: String) {
        var list = records()
        guard let i = list.firstIndex(where: { $0.appleID == appleID }),
              let t = list[i].teams.first(where: { $0.id == id }) else { return }
        list[i].teamID = t.id; list[i].teamType = t.type; list[i].teamName = t.name
        write(list)
    }
    /// The team identifier the user picked for this Apple ID, if any.
    public static func chosenTeamID(for appleID: String) -> String? {
        let id = records().first(where: { $0.appleID == appleID })?.teamID ?? ""
        return id.isEmpty ? nil : id
    }
    /// Reconstruct (account, session) with a FRESH anisette (durable creds are dsid+authToken).
    public static func session(for appleID: String) -> (ALTAccount, ALTAppleAPISession)? {
        guard let r = records().first(where: { $0.appleID == appleID }), let anisette = Anisette.fresh() else { return nil }
        let account = ALTAccount()
        account.appleID = r.appleID; account.identifier = r.identifier
        account.firstName = r.firstName; account.lastName = r.lastName
        return (account, ALTAppleAPISession(dsid: r.dsid, authToken: r.authToken, anisetteData: anisette))
    }
    public static var appleIDs: [String] { records().map(\.appleID) }
}

// MARK: - Keychain (Apple-ID password, so the refresh daemon can re-auth unattended)

public enum Keychain {
    private static let service = "com.decent.sidestep.appleid"
    public static func savePassword(_ password: String, for appleID: String) {
        let acct = appleID.data(using: .utf8)!, pw = password.data(using: .utf8)!
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: appleID]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = pw; _ = acct
        SecItemAdd(add as CFDictionary, nil)
    }
    public static func password(for appleID: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: appleID,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    public static func clear(_ appleID: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: appleID] as CFDictionary)
    }
}

// MARK: - Certificate persistence (reuse ONE cert per account so re-signing one app
// doesn't invalidate the account's other apps — a free ID has only one cert)

public enum CertStore {
    static func path(_ appleID: String) -> String { SideStepSupportDir + "/cert-\(Sideloader.sanitize(appleID)).json" }
    public static func save(_ cert: ALTCertificate, for appleID: String) {
        guard let data = cert.data, let key = cert.privateKey else { return }
        let obj: [String: String] = ["serial": cert.serialNumber, "data": data.base64EncodedString(), "key": key.base64EncodedString()]
        try? FileManager.default.createDirectory(atPath: SideStepSupportDir, withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let p = path(appleID)
        try? d.write(to: URL(fileURLWithPath: p))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
    }
    public static func load(for appleID: String) -> ALTCertificate? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path(appleID))),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: String],
              let ds = obj["data"], let ks = obj["key"],
              let data = Data(base64Encoded: ds), let key = Data(base64Encoded: ks),
              let cert = ALTCertificate(data: data) else { return nil }
        cert.privateKey = key
        return cert
    }
    public static func clear(_ appleID: String) { try? FileManager.default.removeItem(atPath: path(appleID)) }
}

// MARK: - AltStore-format source + tracked apps

public struct SourceApp: Decodable, Identifiable, Sendable {
    public var name: String
    public var bundleIdentifier: String
    public var downloadURL: String
    public var version: String?
    public var localizedDescription: String?
    public var iconURL: String?
    public var developerName: String?
    public var sourceName: String = ""      // which source it came from (set by the catalog)
    public var sourceWebsite: String = ""   // the source's own website (fallback "more info")
    public var id: String { bundleIdentifier }

    /// A "more info" page for this app: the GitHub project behind a github.com /
    /// raw.githubusercontent.com download URL, else the source's own website. nil only
    /// when neither exists, so the UI links whenever a URL is available.
    public var infoURL: URL? {
        // 1) the GitHub project behind a github download URL
        if let d = URL(string: downloadURL), let host = d.host,
           host == "github.com" || host == "raw.githubusercontent.com" {
            let parts = d.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            if parts.count >= 2 { return URL(string: "https://github.com/\(parts[0])/\(parts[1])") }
        }
        // 2) fall back to the source's own website (for non-GitHub downloads)
        if !sourceWebsite.isEmpty, let u = URL(string: sourceWebsite),
           let s = u.scheme, s == "http" || s == "https" { return u }
        return nil
    }

    enum CodingKeys: String, CodingKey { case name, bundleIdentifier, downloadURL, version, versions, localizedDescription, iconURL, developerName }
    struct Ver: Decodable { var downloadURL: String?; var version: String? }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        bundleIdentifier = (try? c.decode(String.self, forKey: .bundleIdentifier)) ?? ""
        localizedDescription = try? c.decode(String.self, forKey: .localizedDescription)
        iconURL = try? c.decode(String.self, forKey: .iconURL)
        developerName = try? c.decode(String.self, forKey: .developerName)
        // v1 has top-level downloadURL/version; v2 nests them under versions[0].
        let versions = (try? c.decode([Ver].self, forKey: .versions)) ?? []
        downloadURL = (try? c.decode(String.self, forKey: .downloadURL)) ?? versions.first?.downloadURL ?? ""
        version = (try? c.decode(String.self, forKey: .version)) ?? versions.first?.version
    }
    // Manual init so the catalog can stamp sourceName.
    public init(name: String, bundleIdentifier: String, downloadURL: String, version: String?,
                localizedDescription: String?, iconURL: String?, developerName: String?, sourceName: String) {
        self.name = name; self.bundleIdentifier = bundleIdentifier; self.downloadURL = downloadURL
        self.version = version; self.localizedDescription = localizedDescription; self.iconURL = iconURL
        self.developerName = developerName; self.sourceName = sourceName
    }
}
struct AltSource: Decodable { var name: String?; var website: String?; var apps: [SourceApp] }

public struct TrackedApp: Codable, Identifiable {
    public var name: String
    public var origBundleID: String
    public var source: String          // cached .app path (or https/local before caching)
    public var installedBundleID: String
    public var appleID: String = ""    // which account signed it
    public var udid: String = ""       // which device it was installed to
    public var deviceName: String = ""
    public var validityDays: Int = 7   // 7 (free) or 365 (paid)
    public var appIDIdentifier: String = ""   // Apple App-ID id, for deletion
    public var lastInstalled: Double?
    public var version: String = ""           // the app's CFBundleShortVersionString
    public var githubRepo: String = ""        // "owner/name" if installed from GitHub Releases
    public var githubTag: String = ""         // the release tag of the currently-installed build
    public var origin: String = ""            // how it was found: an http source URL, or the .ipa path
    public var id: String { installedBundleID + "@" + udid }

    /// True when SideStep will fetch NEW versions for this app (GitHub repo or an
    /// AltStore/http source). A plain local .ipa is a one-time install (re-signed to
    /// stay alive, but the content never changes).
    public var autoUpdates: Bool { !githubRepo.isEmpty || origin.hasPrefix("http") }
    /// Human-readable "how this app was found", for the UI + the on-device overlay.
    public var foundVia: String {
        if !githubRepo.isEmpty { return "GitHub — \(githubRepo)" }
        if origin.hasPrefix("http") { return "AltStore — \(origin)" }
        if !origin.isEmpty { return "File — \((origin as NSString).lastPathComponent)" }
        return "File"
    }
    /// Seconds until the provisioning profile expires (negative = expired).
    public var secondsUntilExpiry: Double? {
        guard let li = lastInstalled else { return nil }
        return (li + Double(validityDays) * 86400) - Date().timeIntervalSince1970
    }
}

extension TrackedApp {
    // Lenient decode so entries written before the newer fields still load.
    enum CodingKeys: String, CodingKey { case name, origBundleID, source, installedBundleID, appleID, udid, deviceName, validityDays, appIDIdentifier, lastInstalled, version, githubRepo, githubTag, origin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        origBundleID = try c.decode(String.self, forKey: .origBundleID)
        source = try c.decode(String.self, forKey: .source)
        installedBundleID = try c.decode(String.self, forKey: .installedBundleID)
        appleID = try c.decodeIfPresent(String.self, forKey: .appleID) ?? ""
        udid = try c.decodeIfPresent(String.self, forKey: .udid) ?? ""
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        validityDays = try c.decodeIfPresent(Int.self, forKey: .validityDays) ?? 7
        appIDIdentifier = try c.decodeIfPresent(String.self, forKey: .appIDIdentifier) ?? ""
        lastInstalled = try c.decodeIfPresent(Double.self, forKey: .lastInstalled)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        githubRepo = try c.decodeIfPresent(String.self, forKey: .githubRepo) ?? ""
        githubTag = try c.decodeIfPresent(String.self, forKey: .githubTag) ?? ""
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
    }
}

public enum Tracked {
    static let path = SideStepSupportDir + "/tracked.json"
    public static func all() -> [TrackedApp] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let list = try? JSONDecoder().decode([TrackedApp].self, from: d) else { return [] }
        return list
    }
    static func write(_ list: [TrackedApp]) {
        try? FileManager.default.createDirectory(atPath: SideStepSupportDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: URL(fileURLWithPath: path)) }
    }
    public static func upsert(_ app: TrackedApp) {
        var list = all().filter { !($0.installedBundleID == app.installedBundleID && $0.udid == app.udid) }
        list.append(app)
        write(list)
    }
    public static func remove(installedBundleID: String, udid: String) {
        write(all().filter { !($0.installedBundleID == installedBundleID && $0.udid == udid) })
    }
}

// MARK: - Provision + sign + install

public struct Sideloader {
    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { var e = ProcessInfo.processInfo.environment; env.forEach { e[$0] = $1 }; p.environment = e }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Like run(), but delivers each output line to `onLine` as it arrives (so
    /// progress can be forwarded live). Returns the full combined output.
    static func runStreaming(_ tool: String, _ args: [String], cwd: URL? = nil, onLine: (String) -> Void) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let h = pipe.fileHandleForReading
        try p.run()
        var full = "", buf = ""
        while case let d = h.availableData, !d.isEmpty {
            let s = String(decoding: d, as: UTF8.self); full += s; buf += s
            while let nl = buf.firstIndex(of: "\n") {
                let line = String(buf[..<nl]); buf.removeSubrange(...nl)
                if !line.isEmpty { onLine(line) }
            }
        }
        if !buf.isEmpty { onLine(buf) }
        p.waitUntilExit()
        return full
    }

    static func plistValue(_ key: String, _ plistPath: String) -> String? {
        (try? run("/usr/libexec/PlistBuddy", ["-c", "Print :\(key)", plistPath]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func sanitize(_ s: String) -> String {
        let r = s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        return r.isEmpty ? "app" : r
    }
    /// The bundled libimobiledevice helper (device list/install/uninstall). No Python needed.
    static func helperPath() -> String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/idevice/idevicehelper").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return NSString(string: "~/altstore-fork/imd/dist/idevice/idevicehelper").expandingTildeInPath  // dev fallback
    }

    // MARK: - Developer Mode (iOS 16+)

    public enum DevMode { case enabled, disabled, unsupported, unknown }

    /// Where to point the user when Developer Mode is off.
    public static let developerModeHelp =
        "On the device, open Settings ▸ Privacy & Security ▸ scroll to the bottom ▸ Developer Mode ▸ turn it On. " +
        "The device restarts; after it reboots, unlock it and tap “Turn On” to confirm. (Requires iOS/iPadOS 16 or later.)"

    static func devModeCtlPath() -> String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/idevice/idevicedevmodectl").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return NSString(string: "~/altstore-fork/AltSign-SS/Helpers/idevice/idevicedevmodectl").expandingTildeInPath
    }

    /// Query Developer Mode for a USB-connected device. Returns .unknown for a
    /// device that isn't reachable over USB (e.g. Wi-Fi-only refreshes) so callers
    /// don't block on it.
    public static func developerMode(_ udid: String) -> DevMode {
        guard let out = try? run(devModeCtlPath(), ["-u", udid, "list"]) else { return .unknown }
        for line in out.split(separator: "\n") where line.contains(udid) {
            let l = line.lowercased()
            if l.contains("enabled") { return .enabled }
            if l.contains("disabled") { return .disabled }
            if l.contains("unsupported") || l.contains("not supported") { return .unsupported }
        }
        if out.lowercased().contains("unsupported") { return .unsupported }
        return .unknown
    }

    /// Make the "Developer Mode" row appear in Settings (it's hidden until a dev
    /// tool has connected). Best-effort; needs the device on USB.
    @discardableResult
    public static func revealDeveloperMode(_ udid: String) -> Bool {
        ((try? run(devModeCtlPath(), ["-u", udid, "reveal"])) != nil)
    }

    public enum DevModeEnable { case enabled, rebooting, needsManual, unknown }

    /// Try to turn Developer Mode ON directly. Uses `arm` (NOT `enable`): arm returns
    /// immediately after asking iOS to reboot into Developer Mode, whereas `enable`
    /// blocks ~100s waiting for the whole reboot/reconnect cycle (which looks like a
    /// hang). This SUCCEEDS only when the device is unlocked, trusted, and has NO
    /// passcode — iOS then reboots and, on unlock, prompts the user to confirm. With a
    /// passcode iOS refuses, and the tool reveals the Settings row instead; the user
    /// must flip it (there is NO API to open/navigate the device's Settings app). Call
    /// off the main thread. The full command output is logged for diagnosis.
    public static func tryEnableDeveloperMode(_ udid: String) -> DevModeEnable {
        guard let out = try? run(devModeCtlPath(), ["-u", udid, "arm"]) else { return .unknown }
        let l = out.lowercased()
        print("[SideStep] tryEnableDeveloperMode(arm): \(out.replacingOccurrences(of: "\n", with: " ⏎ "))")
        if l.contains("already enabled") || l.contains("successfully enabled") { return .enabled }
        if l.contains("armed") || l.contains("will reboot") || l.contains("waiting for reboot") { return .rebooting }
        if l.contains("passcode") || l.contains("on the device itself") { return .needsManual }
        return .unknown
    }

    static func ipInstallPath() -> String {
        if let p = ProcessInfo.processInfo.environment["IWISH_IPINSTALL"], !p.isEmpty { return p }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/idevice/idevice_ipinstall").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return NSString(string: "~/altstore-fork/AltSign-SS/Helpers/idevice/idevice_ipinstall").expandingTildeInPath  // dev fallback (heartbeat+sync)
    }

    /// The prebuilt beacon dylib injected into every app we install.
    static func beaconDylibPath() -> String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/beacon_payload.dat").path
        if FileManager.default.isReadableFile(atPath: bundled) { return bundled }
        return NSString(string: "~/altstore-fork/AltSign-SS/Helpers/beacon_payload.dat").expandingTildeInPath  // dev fallback
    }

    static func wifiEnablePath() -> String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/idevice/idevice_wifienable").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return NSString(string: "~/altstore-fork/AltSign-SS/Helpers/idevice/idevice_wifienable").expandingTildeInPath  // dev fallback
    }

    /// Best-effort: over the USB trusted session, turn on the device's "Show this
    /// device when on Wi-Fi" (lockdown EnableWifiConnections) so future beacon /
    /// direct-IP installs can open a trusted Wi-Fi session. The tool reads the value
    /// back to confirm the change stuck; only if it genuinely couldn't do we tell the
    /// user how to set it by hand — they should otherwise never see that message.
    static func enableWifiSync(_ udid: String, log: (String) -> Void) {
        let tool = wifiEnablePath()
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let out = (try? run(tool, [udid])) ?? ""
        if out.contains("WIFI-SYNC OK") {
            log("Wi-Fi updates are enabled on this device.")
        } else if out.contains("WIFI-SYNC MANUAL") {
            log("⚠️ Couldn’t turn on Wi-Fi updates for this device automatically. To enable wireless updates: keep it connected by USB, open Finder → click the device → General tab → tick “Show this iPhone/iPad when on Wi-Fi” → Apply. (USB installs keep working regardless.)")
        }
        // WIFI-SYNC SKIP / empty output: device isn't on USB, or tool missing — stay silent.
    }

    /// This Mac's own LAN IPv4 on the interface that would reach `facing` (the
    /// device IP), via the connected-UDP-socket getsockname trick. The beacon
    /// unicasts to this as its fast path; broadcast + Bonjour cover IP changes.
    static func localIPv4(facing: String?) -> String {
        let target = (facing?.isEmpty == false ? facing! : "8.8.8.8")
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { return "" }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = (53 as in_port_t).bigEndian
        inet_pton(AF_INET, target, &addr.sin_addr)
        let cr = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if cr != 0 { return "" }
        var local = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gr = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        if gr != 0 { return "" }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    /// Connected iOS devices as (udid, name, conn) where conn is "usb" or "wifi".
    /// Empty if none / tooling missing.
    public static func connectedDevices() -> [(udid: String, name: String, conn: String)] {
        let helper = helperPath()
        let out: String
        do { out = try run(helper, ["list"]) }
        catch {
            print("[SideStep] connectedDevices: helper FAILED to launch (\(helper)): \(String(reflecting: error))")
            return []
        }
        print("[SideStep] connectedDevices: helper=\(helper)")
        print("[SideStep] connectedDevices: raw output = \(out.isEmpty ? "(empty)" : out.replacingOccurrences(of: "\n", with: " ⏎ "))")
        func isUDID(_ s: String) -> Bool {
            s.allSatisfy { $0.isHexDigit || $0 == "-" } && (s.count == 40 || (s.count == 25 && s.contains("-")))
        }
        var seen = Set<String>()
        return out.split(separator: "\n").compactMap { line -> (udid: String, name: String, conn: String)? in
            let parts = line.split(separator: "\t").map(String.init)
            guard let u = parts.first, isUDID(u), !seen.contains(u) else { return nil }
            seen.insert(u)
            let name = parts.count > 1 && !parts[1].isEmpty ? parts[1] : u
            let conn = parts.count > 2 ? parts[2] : "usb"   // older helpers omit the column
            DeviceIPCache.rememberName(u, name: name)   // so Wi-Fi-only installs can still show a name
            return (u, name, conn)
        }
    }

    // MARK: source + download

    static func parseSource(_ data: Data) -> [SourceApp] {
        (try? JSONDecoder().decode(AltSource.self, from: data))?.apps ?? []
    }
    public static func fetchSource(_ urlString: String) async throws -> [SourceApp] {
        guard let url = URL(string: urlString) else { throw SideErr.fail("bad source URL") }
        let (data, _) = try await URLSession.shared.data(from: url)
        return parseSource(data)
    }
    /// Read an AltStore-format source from a local .json file.
    public static func loadSourceFile(_ path: String) throws -> [SourceApp] {
        let apps = parseSource(try Data(contentsOf: URL(fileURLWithPath: path)))
        if apps.isEmpty { throw SideErr.fail("no apps found (is this an AltStore-format source JSON?)") }
        return apps
    }
    /// Download + install one app from a parsed source (works regardless of where the catalog came from).
    @discardableResult
    public static func installSourceApp(account: ALTAccount, session: ALTAppleAPISession,
                                        app: SourceApp, iPadUDID: String,
                                        confirm: @escaping (_ app: String, _ bundleID: String) async -> Bool = { _, _ in true },
                                        log: @escaping (String) -> Void) async throws -> String {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("isl-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let appPath = try await downloadAndUnzipApp(app.downloadURL, into: work, log: log)
        return try await install(account: account, session: session, appPath: appPath.path,
                                 source: app.downloadURL, iPadUDID: iPadUDID, confirm: confirm, log: log)
    }

    /// Download an IPA and unzip it, returning the path to the .app inside Payload/.
    static func downloadAndUnzipApp(_ urlString: String, into work: URL, log: @escaping (String) -> Void) async throws -> URL {
        guard let url = URL(string: urlString) else { throw SideErr.fail("bad download URL") }
        log("Downloading \(url.lastPathComponent)…")
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let ipa = work.appendingPathComponent("dl.ipa")
        try? FileManager.default.removeItem(at: ipa)
        try FileManager.default.moveItem(at: tmp, to: ipa)
        try run("/usr/bin/unzip", ["-q", ipa.path, "-d", work.path])
        let payload = work.appendingPathComponent("Payload")
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: payload.path)) ?? []
        guard let appName = apps.first(where: { $0.hasSuffix(".app") }) else { throw SideErr.fail("no .app in IPA") }
        return payload.appendingPathComponent(appName)
    }

    // MARK: the pipeline

    /// Provision + sign + install the .app at `appPath`. Records it for refresh.
    /// `source` is what refresh will re-install from (an https IPA URL or the local .app path).
    @discardableResult
    /// Ensure a usable dev cert for the account+team. Reuses a persisted cert if it's still
    /// valid on Apple's side; only rotates (revoke+new) when there isn't one — so re-signing
    /// one app never invalidates the account's other apps.
    static func provisionCertificate(account: ALTAccount, session: ALTAppleAPISession, team: ALTTeam,
                                     log: @escaping (String) -> Void) async throws -> ALTCertificate {
        let api = ALTAppleAPI.sharedAPI
        let existing: [ALTCertificate] = try await cont { api.fetchCertificates(for: team, session: session, completionHandler: $0) }
        if let stored = CertStore.load(for: account.appleID), stored.privateKey != nil,
           existing.contains(where: { $0.serialNumber == stored.serialNumber }) {
            log("reusing existing certificate")
            return stored
        }
        log("issuing a new certificate…")
        // Free teams allow exactly ONE dev cert, so we must revoke the old ones to stay under the
        // limit. Paid teams (e.g. a company team) can hold many certs and those belong to other
        // developers/machines — NEVER blanket-revoke them; just add ours alongside.
        if team.type == .free {
            for old in existing {
                _ = try? await withCheckedThrowingContinuation { (cc: CheckedContinuation<Bool, Error>) in
                    api.revoke(old, for: team, session: session) { ok, e in ok ? cc.resume(returning: true) : cc.resume(throwing: e ?? SideErr.fail("revoke")) }
                }
            }
        }
        let newCert: ALTCertificate = try await cont { api.addCertificate(machineName: "SideStep", to: team, session: session, completionHandler: $0) }
        // submitDevelopmentCSR returns metadata + our key but not cert bytes; fetch list + match by serial.
        let all: [ALTCertificate] = try await cont { api.fetchCertificates(for: team, session: session, completionHandler: $0) }
        guard let cert = all.first(where: { $0.serialNumber == newCert.serialNumber }) else { throw SideErr.fail("new cert not in list") }
        cert.privateKey = newCert.privateKey
        CertStore.save(cert, for: account.appleID)
        return cert
    }

    /// Refresh each saved account's team list once, in the background (no device / no signing).
    /// Populates the per-account team picker and lets the refresh daemon honor the chosen team.
    public static func populateTeamsInBackground() {
        Task.detached(priority: .utility) {
            for appleID in AccountStore.appleIDs {
                guard let (a, s) = AccountStore.session(for: appleID) else { continue }
                let teams = await fetchTeamInfos(account: a, session: s)
                if !teams.isEmpty { AccountStore.setTeams(appleID, teams) }
            }
        }
    }

    /// Every team an Apple ID belongs to, as persistable TeamInfo.
    public static func fetchTeamInfos(account: ALTAccount, session: ALTAppleAPISession) async -> [TeamInfo] {
        guard let teams: [ALTTeam] = try? await cont({ ALTAppleAPI.sharedAPI.fetchTeams(for: account, session: session, completionHandler: $0) }) else { return [] }
        return teams.map { TeamInfo(id: $0.identifier, name: $0.name, type: $0.type.rawValue) }
    }

    /// Resolve which ALTTeam to sign with: the user's saved choice if present, else the old
    /// free-preferring default (keeps single-team / pre-existing accounts working unchanged).
    static func resolveTeam(for account: ALTAccount, from teams: [ALTTeam]) -> ALTTeam? {
        if let id = AccountStore.chosenTeamID(for: account.appleID),
           let t = teams.first(where: { $0.identifier == id }) { return t }
        return teams.first(where: { $0.type == .free }) ?? teams.first
    }

    @discardableResult
    public static func install(account: ALTAccount, session: ALTAppleAPISession,
                               appPath: String, source: String, iPadUDID: String,
                               github: (repo: String, tag: String)? = nil,
                               confirm: @escaping (_ app: String, _ bundleID: String) async -> Bool = { _, _ in true },
                               log: @escaping (String) -> Void) async throws -> String {
        // Anti-piracy screening (before any Apple API work, and before we rewrite the
        // bundle id): refuse known pirate sources/files outright; confirm a known paid app.
        switch Blocklist.shared.screen(appPath: appPath, origin: source) {
        case .allow: break
        case .block(let why):
            throw SideErr.fail("🚫 \(why) SideStep won't sideload pirated apps.")
        case .warnPaid(let app, let bid):
            if await confirm(app, bid) { log("\(app): user confirmed they have the rights — continuing") }
            else { throw SideErr.fail("Install cancelled — \(app) looks like a paid App Store app.") }
        }
        let api = ALTAppleAPI.sharedAPI

        let teams: [ALTTeam] = try await cont { api.fetchTeams(for: account, session: session, completionHandler: $0) }
        guard let team = resolveTeam(for: account, from: teams) else { throw SideErr.fail("No teams on this Apple ID") }
        log("Team: \(team.name). Registering iPad…")
        // Keep the registration error — Apple returns 5405 ("maximum number of
        // registered iPad devices") here, and we must surface it rather than sign an
        // app the device isn't provisioned for and falsely report success.
        let regError: Error? = await withCheckedContinuation { (c: CheckedContinuation<Error?, Never>) in
            api.registerDevice(name: "iPad", identifier: iPadUDID, type: .iPad, team: team, session: session) { _, err in c.resume(returning: err) }
        }

        let cert = try await provisionCertificate(account: account, session: session, team: team, log: log)

        // stage a copy, derive a team-unique bundle id from the app itself
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sidestep-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let appCopy = work.appendingPathComponent("app.app")
        try fm.copyItem(at: URL(fileURLWithPath: appPath), to: appCopy)
        let plist = appCopy.appendingPathComponent("Info.plist").path
        let displayName = plistValue("CFBundleDisplayName", plist) ?? plistValue("CFBundleName", plist)
            ?? (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let origBundleID = plistValue("CFBundleIdentifier", plist) ?? "app"
        let appVersion = plistValue("CFBundleShortVersionString", plist) ?? ""
        let bundleID = "com.sidestep.\(sanitize(displayName)).\(team.identifier)".lowercased()

        // Cache a copy of the app so future refreshes never need the original json/ipa/URL.
        let cacheDir = SideStepSupportDir + "/apps"
        try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let cachePath = cacheDir + "/\(sanitize(bundleID)).app"
        if URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path != URL(fileURLWithPath: cachePath).resolvingSymlinksInPath().path {
            try? fm.removeItem(atPath: cachePath)
            try? fm.copyItem(atPath: appPath, toPath: cachePath)
        }
        log("Creating App ID + profile for \(displayName)…")

        let existing = try await api.fetchAppIDs(for: team, session: session)
        let appID: ALTAppID
        if let f = existing.first(where: { $0.bundleIdentifier == bundleID }) { appID = f }
        else { appID = try await api.addAppID(withName: "\(displayName) (SideStep)", bundleIdentifier: bundleID, team: team, session: session) }
        let profile = try await api.fetchProvisioningProfile(for: appID, deviceType: .iPad, team: team, session: session)
        // If the target device isn't in the profile, iOS will reject the install on
        // device with 0xe8008015 ("no valid provisioning profile") and show the user a
        // misleading "integrity could not be verified" — even though SideStep signed
        // fine. Catch it here with the real reason instead of reporting a false success.
        if !profile.deviceIDs.contains(where: { $0.caseInsensitiveCompare(iPadUDID) == .orderedSame }) {
            let devName = connectedDevices().first(where: { $0.udid == iPadUDID })?.name
                ?? DeviceIPCache.name(for: iPadUDID) ?? ""
            let regText = (regError.map { "\($0.localizedDescription) \(String(describing: $0))" } ?? "").lowercased()
            if regText.contains("maximum number of registered") || regText.contains("5405") {
                let others = AccountStore.records().map { $0.appleID }.filter { $0 != account.appleID }
                log("device \(iPadUDID) not provisioned — Apple device limit reached on \(account.appleID)")
                throw SideErr.deviceLimit(appleID: account.appleID, deviceName: devName, bundleID: origBundleID, others: others)
            }
            throw SideErr.fail("\(devName.isEmpty ? "This device" : "“\(devName)”") isn’t registered with \(account.appleID), so iOS won’t install this app on it. Connect it once by USB and try again."
                + (regError.map { " (\($0.localizedDescription))" } ?? ""))
        }
        log("Signing \(displayName)… (profile exp \(profile.expirationDate))")

        try run("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleIdentifier \(bundleID)", plist])

        // Instrument with the wireless self-updater (best-effort) BEFORE signing,
        // so zsign covers the injected dylib. Disable with IWISH_NO_BEACON.
        if ProcessInfo.processInfo.environment["IWISH_NO_BEACON"] == nil {
            let macIP = localIPv4(facing: ProcessInfo.processInfo.environment["IWISH_IP"])
            // "how found" + update mode, for the on-device overlay.
            let via: String = github.map { "GitHub — \($0.repo)" }
                ?? (source.hasPrefix("http") ? "AltStore — \(source)"
                    : (source.isEmpty ? "File" : "File — \((source as NSString).lastPathComponent)"))
            let auto = github != nil || source.hasPrefix("http")
            BeaconInjector.instrument(appDir: appCopy, dylibSource: beaconDylibPath(),
                                      macIP: macIP, udid: iPadUDID, bundleID: bundleID,
                                      updateInterval: team.type == .free ? 86400 : 7 * 86400,
                                      foundVia: via, autoUpdates: auto, log: log)
        }

        let signer = ALTSigner(team: team, certificate: cert)
        _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, Error>) in
            _ = signer.signApp(at: appCopy, provisioningProfiles: [profile]) { ok, e in ok ? c.resume(returning: true) : c.resume(throwing: e ?? SideErr.fail("signApp")) }
        }
        // A USB device with Developer Mode off will reject the install with a
        // cryptic AMFI error — catch it here and tell the user exactly what to do.
        if developerMode(iPadUDID) == .disabled {
            revealDeveloperMode(iPadUDID)   // make the Settings row appear
            throw SideErr.fail("Developer Mode is turned off on this device. \(developerModeHelp) "
                + "(I’ve made the Developer Mode menu appear — enable it, then install again.)")
        }

        log("Installing on iPad…")

        let payload = work.appendingPathComponent("Payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try fm.moveItem(at: appCopy, to: payload.appendingPathComponent("\(sanitize(displayName)).app"))
        let ipa = work.appendingPathComponent("out.ipa")
        try run("/usr/bin/zip", ["-qXr9", ipa.path, "Payload"], cwd: work)
        // Debug aid: keep a copy of the signed IPA for inspection.
        if let keep = ProcessInfo.processInfo.environment["IWISH_KEEP_IPA"], !keep.isEmpty {
            try? fm.removeItem(atPath: keep)
            try? fm.copyItem(at: ipa, to: URL(fileURLWithPath: keep))
            log("kept signed ipa at \(keep)")
        }

        // Route by the device's ACTUAL connection type — not by whether IWISH_IP
        // happens to be set. A device present on USB installs over usbmux (no network
        // pairing needed, always reliable); only a Wi-Fi-only device needs direct-IP.
        // (The beacon still sets IWISH_IP so we know the device's IP for the Wi-Fi case.)
        let conn = connectedDevices().first(where: { $0.udid == iPadUDID })?.conn
        // On USB we hold a trusted session — use it to switch on the device's
        // "Show when on Wi-Fi" flag so future wireless updates work with no manual step.
        if conn == "usb" { enableWifiSync(iPadUDID, log: log) }
        let envIP = ProcessInfo.processInfo.environment["IWISH_IP"].flatMap { $0.isEmpty ? nil : $0 }
        // A manual Refresh has no beacon to hand over the device IP, so fall back to the
        // last IP we learned from this device's beacon — lets a Wi-Fi-only device refresh
        // on demand, not only when it beacons.
        let targetIP = envIP ?? DeviceIPCache.ip(for: iPadUDID)
        func usbInstall() throws {
            let r = try run(helperPath(), ["install", iPadUDID, ipa.path], cwd: work)
            log("install: \(r.split(separator: "\n").last.map(String.init) ?? r)")
            guard r.contains("INSTALL OK") else { throw SideErr.fail("install failed: \(r.suffix(160))") }
        }
        if conn == "usb" {
            // USB (usbmux) — reliable, no network pairing needed.
            try usbInstall()
        } else if let ip = targetIP {
            // Direct-IP install: connect straight to the device's IP (beacon-supplied or
            // remembered), bypassing usbmux's flaky Bonjour discovery.
            log("Installing by direct IP \(ip)…")
            let ipOut = try runStreaming(ipInstallPath(), [iPadUDID, ip, ipa.path], cwd: work, onLine: { log($0) })
            if !ipOut.contains("DIRECT-IP INSTALL OK") {
                if connectedDevices().contains(where: { $0.udid == iPadUDID }) {
                    // Still reachable via usbmux (cable, or Wi-Fi-listed) — let it route.
                    log("Direct-IP failed; device is in the device list — falling back to usbmux…")
                    try usbInstall()
                } else {
                    let lc = ipOut.lowercased()
                    if lc.contains("pair record") || lc.contains("handshake by ip") || lc.contains("err -21") || lc.contains("err -8") {
                        throw SideErr.fail("Couldn’t open a trusted Wi-Fi session with this device. Two things enable wireless installs: (1) plug it in once via USB, unlock, and tap “Trust This Computer”; and (2) in Finder, click the device → General → tick “Show this iPhone/iPad when on Wi-Fi” → Apply. Then keep the device unlocked and try again. (Until then, a USB cable always works.)")
                    }
                    throw SideErr.fail("Wi-Fi install failed. Make sure the device is unlocked and on the same network, then try again. (\(ipOut.suffix(160)))")
                }
            }
        } else if connectedDevices().contains(where: { $0.udid == iPadUDID }) {
            // In the usbmux list (Wi-Fi sync) but we have no IP for it — let usbmux route it.
            try usbInstall()
        } else {
            // Not on USB, not in the device list, no remembered IP — we can't reach it.
            throw SideErr.fail("Can’t reach this device to update it. Open \(displayName) on the device once so it checks in over Wi-Fi, or connect it by USB — then tap Refresh again.")
        }

        // Prefer the live USB/Wi-Fi listing; fall back to a name remembered from a
        // prior USB connection or beacon, so a Wi-Fi-only install still shows a real
        // name instead of the raw UDID.
        let deviceName = connectedDevices().first(where: { $0.udid == iPadUDID })?.name
            ?? DeviceIPCache.name(for: iPadUDID) ?? ""
        var rec = TrackedApp(name: displayName, origBundleID: origBundleID, source: cachePath,
                             installedBundleID: bundleID, appleID: account.appleID, udid: iPadUDID,
                             deviceName: deviceName, validityDays: team.type == .free ? 7 : 365,
                             appIDIdentifier: appID.identifier, lastInstalled: Date().timeIntervalSince1970)
        rec.version = appVersion
        rec.origin = source   // how it was found (http source URL, or the .ipa/.app path)
        if let github { rec.githubRepo = github.repo; rec.githubTag = github.tag }
        Tracked.upsert(rec)
        AppIconCache.extract(fromApp: cachePath, bundleID: bundleID)   // best-effort icon for the UI
        try? fm.removeItem(at: work)
        log("found via: \(rec.foundVia) — \(rec.autoUpdates ? "app keeps up to date" : "one-time install")")
        return "✅ Installed \(displayName) (\(bundleID))."
    }

    /// Install a chosen app from an AltStore-format source URL.
    @discardableResult
    public static func installFromSource(account: ALTAccount, session: ALTAppleAPISession,
                                         sourceURL: String, bundleIdentifier: String, iPadUDID: String,
                                         log: @escaping (String) -> Void) async throws -> String {
        let apps = try await fetchSource(sourceURL)
        guard let app = apps.first(where: { $0.bundleIdentifier == bundleIdentifier }) ?? apps.first else { throw SideErr.fail("app not found in source") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("sidestep-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let appPath = try await downloadAndUnzipApp(app.downloadURL, into: work, log: log)
        return try await install(account: account, session: session, appPath: appPath.path,
                                 source: app.downloadURL, iPadUDID: iPadUDID, log: log)
    }

    /// Install from a local .ipa (or .app) file.
    @discardableResult
    public static func installFromIPA(account: ALTAccount, session: ALTAppleAPISession,
                                      filePath: String, iPadUDID: String,
                                      github: (repo: String, tag: String)? = nil,
                                      confirm: @escaping (_ app: String, _ bundleID: String) async -> Bool = { _, _ in true },
                                      log: @escaping (String) -> Void) async throws -> String {
        if filePath.hasSuffix(".app") {
            return try await install(account: account, session: session, appPath: filePath, source: filePath, iPadUDID: iPadUDID, github: github, confirm: confirm, log: log)
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("isl-ipa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", filePath, "-d", work.path])
        let payload = work.appendingPathComponent("Payload")
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: payload.path)) ?? []
        guard let appName = apps.first(where: { $0.hasSuffix(".app") }) else { throw SideErr.fail("no .app inside the IPA") }
        return try await install(account: account, session: session,
                                 appPath: payload.appendingPathComponent(appName).path,
                                 source: filePath, iPadUDID: iPadUDID, github: github, confirm: confirm, log: log)
    }

    /// Install the newest `.ipa` from a GitHub repo's releases, remembering the repo
    /// so the daily check + every refresh keep it on the latest release.
    @discardableResult
    public static func installFromGitHub(account: ALTAccount, session: ALTAppleAPISession,
                                         repo: String, iPadUDID: String,
                                         log: @escaping (String) -> Void) async throws -> String {
        guard let rel = await GitHub.latestIPA(repo: repo) else { throw SideErr.fail("no .ipa release found in \(repo)") }
        log("GitHub: \(repo) latest is \(rel.tag) (\(rel.ipaName)) — downloading…")
        let ipa = try await GitHub.downloadIPA(rel)
        defer { try? FileManager.default.removeItem(atPath: ipa) }
        return try await installFromIPA(account: account, session: session, filePath: ipa,
                                        iPadUDID: iPadUDID, github: (repo, rel.tag), log: log)
    }

    /// Free vs paid team info for an account (for showing 7-day vs 1-year).
    public static func accountTeamInfo(account: ALTAccount, session: ALTAppleAPISession) async -> (type: Int, name: String)? {
        guard let teams: [ALTTeam] = try? await cont({ ALTAppleAPI.sharedAPI.fetchTeams(for: account, session: session, completionHandler: $0) }),
              let team = resolveTeam(for: account, from: teams) else { return nil }
        return (team.type.rawValue, team.name)
    }

    /// A WORKING session for this Apple ID: the saved one if it still validates,
    /// otherwise a silent re-login with the Keychain-stored password (so the user
    /// doesn't have to retype anything). Returns nil only if there's no saved
    /// account, or if the re-login needs a 2-factor code we can't supply unattended.
    static func ensureSession(_ appleID: String, log: (String) -> Void) async -> (ALTAccount, ALTAppleAPISession)? {
        guard let pair = AccountStore.session(for: appleID) else { return nil }
        let teams: [ALTTeam]? = try? await cont { ALTAppleAPI.sharedAPI.fetchTeams(for: pair.0, session: pair.1, completionHandler: $0) }
        if teams != nil { return pair }   // saved session still good
        log("session for \(appleID) expired — signing in again…")
        guard let pw = Keychain.password(for: appleID), let anisette = Anisette.fresh() else { return nil }
        let res: (ALTAccount, ALTAppleAPISession)? = try? await withCheckedThrowingContinuation { c in
            ALTAppleAPI.sharedAPI.authenticate(appleID: appleID, password: pw, anisetteData: anisette,
                verificationHandler: { submit in submit(nil) },   // unattended: can't satisfy a 2FA prompt
                completionHandler: { a, s, e in if let a, let s { c.resume(returning: (a, s)) } else { c.resume(throwing: e ?? SideErr.fail("reauth")) } })
        }
        if let r = res { AccountStore.add(account: r.0, session: r.1) }
        return res
    }

    /// Install a tracked app (known from any device) onto a DIFFERENT device, from
    /// whatever source it originally came from. Used by the on-device installer to
    /// copy an app you have on another device onto this one, over Wi-Fi.
    @discardableResult
    public static func installTracked(_ t: TrackedApp, onUDID udid: String,
                                      account: ALTAccount, session: ALTAppleAPISession,
                                      log: @escaping (String) -> Void) async throws -> String {
        if !t.githubRepo.isEmpty {
            return try await installFromGitHub(account: account, session: session, repo: t.githubRepo, iPadUDID: udid, log: log)
        }
        if t.origin.hasPrefix("http") {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("isl-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let appPath = try await downloadAndUnzipApp(t.origin, into: work, log: log)
            return try await install(account: account, session: session, appPath: appPath.path, source: t.origin, iPadUDID: udid, log: log)
        }
        return try await installFromIPA(account: account, session: session, filePath: t.source, iPadUDID: udid, log: log)
    }

    /// Re-sign + (WiFi/USB) re-install one tracked app on its device.
    @discardableResult
    public static func refreshOne(_ t: TrackedApp, log: @escaping (String) -> Void) async throws -> String {
        guard let (account, session) = await ensureSession(t.appleID, log: log) else {
            throw SideErr.fail("Couldn't sign in to \(t.appleID) automatically. Open SideStep and sign in again — you may just need to enter a texted code.")
        }
        // GitHub-sourced apps always push the CURRENT latest release (keeps the device
        // on the newest build), updating the remembered tag.
        if !t.githubRepo.isEmpty, let rel = await GitHub.latestIPA(repo: t.githubRepo) {
            if rel.tag != t.githubTag { log("GitHub: \(t.githubRepo) → \(rel.tag) (was \(t.githubTag.isEmpty ? "none" : t.githubTag))") }
            let ipa = try await GitHub.downloadIPA(rel)
            defer { try? FileManager.default.removeItem(atPath: ipa) }
            return try await installFromIPA(account: account, session: session, filePath: ipa,
                                            iPadUDID: t.udid, github: (t.githubRepo, rel.tag), log: log)
        }
        // AltStore/http source → re-download the current build from the source each time,
        // so the app tracks the source's latest version.
        if t.origin.hasPrefix("http") {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("isl-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let appPath = try await downloadAndUnzipApp(t.origin, into: work, log: log)
            return try await install(account: account, session: session, appPath: appPath.path, source: t.origin, iPadUDID: t.udid, log: log)
        }
        // Local .ipa/.app → re-sign the cached copy (one-time content, just kept alive).
        return try await installFromIPA(account: account, session: session, filePath: t.source, iPadUDID: t.udid, log: log)
    }

    /// Daily sweep: for every GitHub-sourced tracked app whose repo now has a newer
    /// release tag, re-install the latest build (if its device is reachable). The
    /// 7-day refresh handles signing expiry; this handles NEW app versions, so each
    /// app tracks its repo's latest GitHub release.
    public static func checkGitHubUpdates(log: @escaping (String) -> Void) async {
        let apps = Tracked.all().filter { !$0.githubRepo.isEmpty }
        guard !apps.isEmpty else { return }
        let reachable = Set(connectedDevices().map { $0.udid })
        for t in apps {
            guard let rel = await GitHub.latestIPA(repo: t.githubRepo) else { continue }
            guard rel.tag != t.githubTag else { continue }
            guard reachable.contains(t.udid) else {
                log("GitHub: \(t.githubRepo) has \(rel.tag) but \(t.deviceName.isEmpty ? t.udid : t.deviceName) isn't reachable — will retry"); continue
            }
            do { let r = try await refreshOne(t, log: log); log("GitHub update → \(r)") }
            catch { log("GitHub update failed for \(t.githubRepo): \(error)") }
        }
    }

    /// Uninstall from the device, delete its App ID (frees a free-account slot), untrack.
    public static func removeApp(_ t: TrackedApp, log: @escaping (String) -> Void) async {
        let out = (try? run(helperPath(), ["uninstall", t.udid, t.installedBundleID])) ?? ""
        log("uninstall: \(out.split(separator: "\n").last.map(String.init) ?? out)")
        if let (account, session) = AccountStore.session(for: t.appleID),
           let teams: [ALTTeam] = try? await cont({ ALTAppleAPI.sharedAPI.fetchTeams(for: account, session: session, completionHandler: $0) }),
           let team = resolveTeam(for: account, from: teams),
           let appIDs = try? await ALTAppleAPI.sharedAPI.fetchAppIDs(for: team, session: session),
           let appID = appIDs.first(where: { $0.identifier == t.appIDIdentifier || $0.bundleIdentifier == t.installedBundleID }) {
            _ = try? await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, Error>) in
                ALTAppleAPI.sharedAPI.deleteAppID(appID, for: team, session: session) { ok, e in ok ? c.resume(returning: true) : c.resume(throwing: e ?? SideErr.fail("deleteAppID")) }
            }
            log("freed the App ID slot")
        }
        Tracked.remove(installedBundleID: t.installedBundleID, udid: t.udid)
        try? FileManager.default.removeItem(atPath: SideStepSupportDir + "/apps/\(sanitize(t.installedBundleID)).app")
    }

    // MARK: refresh (7-day)

    /// Re-provision + re-sign + reinstall every tracked app, grouped by the account that
    /// installed it and targeting the device it was installed to. Falls back to a silent
    /// re-auth with the keychain-stored password if an account's session has expired.
    public static func refreshAll(log: @escaping (String) -> Void) async throws {
        let tracked = Tracked.all()
        guard !tracked.isEmpty else { log("nothing to refresh"); return }

        // single-flight lock (timer + connect-trigger can both fire) — ignore stale >15min
        let fm = FileManager.default
        let lock = SideStepSupportDir + "/refresh.lock"
        if let attrs = try? fm.attributesOfItem(atPath: lock), let mt = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mt) < 900 { log("another refresh is running — skipping"); return }
        try? fm.createDirectory(atPath: SideStepSupportDir, withIntermediateDirectories: true)
        fm.createFile(atPath: lock, contents: nil)
        defer { try? fm.removeItem(atPath: lock) }

        let now = Date().timeIntervalSince1970
        let connected = Set(connectedDevices().map { $0.udid })
        let fallbackUDID = connectedDevices().first?.udid ?? ""

        var byAccount: [String: [TrackedApp]] = [:]
        for t in tracked {
            let aid = t.appleID.isEmpty ? (AccountStore.appleIDs.first ?? "") : t.appleID
            byAccount[aid, default: []].append(t)
        }

        for (appleID, apps) in byAccount {
            guard var pair = AccountStore.session(for: appleID) else { log("no saved account for \(appleID) — skipping"); continue }
            // validate session; re-auth via keychain if needed
            do { _ = try await cont { ALTAppleAPI.sharedAPI.fetchTeams(for: pair.0, session: pair.1, completionHandler: $0) } }
            catch {
                log("session for \(appleID) expired — re-authenticating…")
                if let pw = Keychain.password(for: appleID), let anisette = Anisette.fresh() {
                    let res: (ALTAccount, ALTAppleAPISession)? = try? await withCheckedThrowingContinuation { c in
                        ALTAppleAPI.sharedAPI.authenticate(appleID: appleID, password: pw, anisetteData: anisette,
                            verificationHandler: { submit in submit(nil) },   // unattended: can't satisfy 2FA
                            completionHandler: { a, s, e in if let a, let s { c.resume(returning: (a, s)) } else { c.resume(throwing: e ?? SideErr.fail("reauth")) } })
                    }
                    if let r = res { pair = r; AccountStore.add(account: r.0, session: r.1) }
                }
            }
            for t in apps {
                // re-sign only once past 70% of the signing window (2 days left on a 7-day free profile)
                if let li = t.lastInstalled, now - li < 0.7 * Double(t.validityDays) * 86400 { log("\(t.name) still fresh — skipping"); continue }
                let udid = (!t.udid.isEmpty && connected.contains(t.udid)) ? t.udid : fallbackUDID
                if udid.isEmpty { log("no device connected for \(t.name) — skipping"); continue }
                do {
                    log("refreshing \(t.name) [\(appleID)]…")
                    if !t.githubRepo.isEmpty, let rel = await GitHub.latestIPA(repo: t.githubRepo) {
                        let ipa = try await GitHub.downloadIPA(rel); defer { try? FileManager.default.removeItem(atPath: ipa) }
                        _ = try await installFromIPA(account: pair.0, session: pair.1, filePath: ipa, iPadUDID: udid, github: (t.githubRepo, rel.tag), log: log)
                    } else if t.origin.hasPrefix("http") {
                        let work = FileManager.default.temporaryDirectory.appendingPathComponent("isl-\(UUID().uuidString)")
                        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                        let appPath = try await downloadAndUnzipApp(t.origin, into: work, log: log)
                        _ = try await install(account: pair.0, session: pair.1, appPath: appPath.path, source: t.origin, iPadUDID: udid, log: log)
                    } else {
                        _ = try await installFromIPA(account: pair.0, session: pair.1, filePath: t.source, iPadUDID: udid, log: log)
                    }
                } catch { log("refresh \(t.name) FAILED: \(error.localizedDescription)") }
            }
        }
    }
}
