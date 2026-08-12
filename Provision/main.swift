// Provision / SideStep CLI.
//   Provision --install                  reuse saved session → install iWish (local build)
//   Provision --source <url> [bundleID]  reuse saved session → install app from an AltStore source
//   Provision --refresh                  re-sign+reinstall every tracked app (used by the LaunchAgent)
//   Provision <apple-id> [--sms]         authenticate (env SIDESTEP_PW / SIDESTEP_2FA) + save session
import Foundation
import AltSign
import SwiftBridge
import SideloaderKit

AltSignLogging.setLogging(true)
func errln(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let args = CommandLine.arguments
let udid = ProcessInfo.processInfo.environment["IWISH_UDID"] ?? "00008112-000A706A0107401E"
let localIWish = NSString(string: "~/iwish/dist/iWish-fw.app").expandingTildeInPath
let sem = DispatchSemaphore(value: 0)

func withSaved(_ work: @escaping (ALTAccount, ALTAppleAPISession) async -> Void) {
    guard let aid = AccountStore.appleIDs.first, let (account, session) = AccountStore.session(for: aid) else {
        errln("No saved account — sign in via the SideStep app once first."); exit(1)
    }
    errln(">>> account \(account.appleID)")
    Task { await work(account, session); sem.signal() }
    sem.wait()
}

// Tier-A logic self-tests: pure functions, no device, no account. Pins the parsing /
// comparison surfaces that have regressed before. Results to stdout; exit 0 iff all pass.
if args.contains("--selftest") {
    var pass = 0, fail = 0
    func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond { pass += 1; print("  PASS  \(name)") }
        else { fail += 1; print("  FAIL  \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
    }
    func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) { check(name, got == want, "got '\(got)', want '\(want)'") }

    // GitHub.normalizeRepo — owner/name, full URLs, .git/trailing slash, junk.
    eq("normalizeRepo owner/name",      GitHub.normalizeRepo("johnbuckman/SideStep"), "johnbuckman/SideStep")
    eq("normalizeRepo full URL",        GitHub.normalizeRepo("https://github.com/johnbuckman/SideStep"), "johnbuckman/SideStep")
    eq("normalizeRepo .git + trailing", GitHub.normalizeRepo("https://github.com/johnbuckman/SideStep.git/"), "johnbuckman/SideStep")
    check("normalizeRepo rejects junk", GitHub.normalizeRepo("not a repo") == nil)

    // AltStore source parse — v1 (top-level) and v2 (versions[0]).
    let v1 = #"{"name":"S","apps":[{"name":"A","bundleIdentifier":"com.a","downloadURL":"https://x/a.ipa","version":"1.2"}]}"#
    let a1 = Sideloader.parseSource(Data(v1.utf8))
    check("parse v1 one app", a1.count == 1)
    eq("parse v1 downloadURL", a1.first?.downloadURL ?? "", "https://x/a.ipa")
    eq("parse v1 version",     a1.first?.version ?? "", "1.2")
    let v2 = #"{"name":"S","apps":[{"name":"B","bundleIdentifier":"com.b","versions":[{"downloadURL":"https://x/b.ipa","version":"2.0"}]}]}"#
    let a2 = Sideloader.parseSource(Data(v2.utf8))
    eq("parse v2 downloadURL (versions[0])", a2.first?.downloadURL ?? "", "https://x/b.ipa")
    eq("parse v2 version (versions[0])",     a2.first?.version ?? "", "2.0")

    // VersionCompare — the self-updater's tag-vs-installed gate.
    check("isNewer 0.2.35 > 0.2.34",   VersionCompare.isNewer("0.2.35", than: "0.2.34"))
    check("isNewer v-prefixed",        VersionCompare.isNewer("v1.0.0", than: "0.9.9"))
    check("isNewer release > beta",    VersionCompare.isNewer("1.0", than: "1.0-beta"))
    check("isNewer equal → false",    !VersionCompare.isNewer("1.0.0", than: "1.0.0"))
    check("isNewer older → false",    !VersionCompare.isNewer("0.1", than: "0.2"))

    // installFailReason — surfaces installd's real line, not a blind tail slice.
    let failOut = ">>> PROGRESS 100 Uploading\n>>> INSTALL FAILED: APIInternalError: Failed to set app extension placeholders\n"
    eq("installFailReason extracts real line", Sideloader.installFailReason(failOut), "APIInternalError: Failed to set app extension placeholders")

    // Device-limit classification — free-account cap vs a generic failure.
    check("deviceLimit: 'maximum number of registered'", Sideloader.isDeviceLimitError("The maximum number of registered devices has been reached."))
    check("deviceLimit: code 5405",                       Sideloader.isDeviceLimitError("error 5405"))
    check("deviceLimit: unrelated → false",              !Sideloader.isDeviceLimitError("some other provisioning error"))

    // Wi-Fi pairing hint — err-21/-8 → pair-over-USB guidance; other failures → nil.
    check("wifiPairingHint: err -21 → guidance",  (Sideloader.wifiPairingHint("DIRECT-IP INSTALL FAILED: handshake by IP err -21")?.contains("Trust This Computer")) == true)
    check("wifiPairingHint: no pair record → nil", Sideloader.wifiPairingHint("some unrelated wifi error") == nil)

    // Subprocess exit-status handling + archive integrity — the fix for the "Could not
    // extract archive" install failure. run() must NOT swallow a non-zero exit (that
    // false-OK produced a corrupt archive that only installd rejected), yet must tolerate
    // unzip's benign exit-1 warnings; verifyArchive() must reject a truncated/garbage .ipa
    // on the Mac (PK-header + central-directory check) instead of shipping it to the device.
    func tmp(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("sstest-\(UUID().uuidString)-\(name)").path
    }
    // run() throws on a real non-zero exit…
    check("run throws on non-zero exit",
          (try? Sideloader.run("/bin/sh", ["-c", "exit 3"])) == nil)
    // …but honors okStatuses (a tolerated code does NOT throw)…
    check("run honors okStatuses (exit 1 tolerated)",
          (try? Sideloader.run("/bin/sh", ["-c", "exit 1"], okStatuses: [0, 1])) != nil)
    // …and a clean exit still returns output.
    check("run returns output on success",
          ((try? Sideloader.run("/bin/echo", ["ok"]))?.contains("ok")) == true)

    // verifyArchive: build a REAL zip, then a truncated copy, then a non-zip file.
    let goodZip = tmp("good.ipa"), truncZip = tmp("trunc.ipa"), notZip = tmp("plain.ipa")
    let stage = tmp("stage")
    try? FileManager.default.createDirectory(atPath: "\(stage)/Payload/A.app", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: "\(stage)/Payload/A.app/x", contents: Data(repeating: 0x41, count: 4096))
    _ = try? Sideloader.run("/usr/bin/zip", ["-qXr", goodZip, "Payload"], cwd: URL(fileURLWithPath: stage))
    check("verifyArchive accepts a valid .ipa", (try? Sideloader.verifyArchive(goodZip)) != nil)
    // Truncate to the first half → central directory unreadable → must be rejected.
    if let whole = try? Data(contentsOf: URL(fileURLWithPath: goodZip)), whole.count > 64 {
        try? whole.prefix(whole.count / 2).write(to: URL(fileURLWithPath: truncZip))
        check("verifyArchive rejects a truncated .ipa", (try? Sideloader.verifyArchive(truncZip)) == nil)
    } else { check("verifyArchive rejects a truncated .ipa", false, "could not build fixture") }
    // A non-zip payload (e.g. an HTML error page saved as .ipa) → no PK header → rejected.
    try? "<html>error</html>".data(using: .utf8)!.write(to: URL(fileURLWithPath: notZip))
    check("verifyArchive rejects a non-zip file", (try? Sideloader.verifyArchive(notZip)) == nil)
    for f in [goodZip, truncZip, notZip, stage] { try? FileManager.default.removeItem(atPath: f) }

    print(fail == 0 ? ">>> SELFTEST OK \(pass) passed" : ">>> SELFTEST FAIL \(fail)/\(pass+fail)")
    exit(fail == 0 ? 0 : 1)
}

// Beacon control-channel server (test-harness side). Listens on the control port; the
// on-device beacon dials OUT to it (reliable direction), sends "HELLO <token> <udid>
// <bundle> <version>", then we send one command and print its reply to stdout.
//   Provision --beacon-serve <CMD> [--wait <sec>]
if let i = args.firstIndex(of: "--beacon-serve"), i + 1 < args.count {
    let cmd = args[i + 1]
    var waitSec = 30.0
    if let wi = args.firstIndex(of: "--wait"), wi + 1 < args.count, let w = Double(args[wi + 1]) { waitSec = w }
    let port: UInt16 = 51236
    let token = ProcessInfo.processInfo.environment["SIDESTEP_BEACON_TOKEN"] ?? "ss-beacon-debug-7f3a"

    let ls = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = INADDR_ANY
    let br = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(ls, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if br != 0 { errln(">>> BEACON-SERVE FAILED: bind :\(port) (in use — stop SideStep or another serve)"); exit(1) }
    listen(ls, 4)
    let fl = fcntl(ls, F_GETFL, 0); _ = fcntl(ls, F_SETFL, fl | O_NONBLOCK)
    errln(">>> waiting up to \(Int(waitSec))s for a device beacon on :\(port)…")
    var conn: Int32 = -1
    let start = Date()
    while Date().timeIntervalSince(start) < waitSec { conn = accept(ls, nil, nil); if conn >= 0 { break }; usleep(200_000) }
    if conn < 0 { errln(">>> BEACON-SERVE: no device connected in \(Int(waitSec))s (is the app foregrounded?)"); exit(2) }
    let cf = fcntl(conn, F_GETFL, 0); _ = fcntl(conn, F_SETFL, cf & ~O_NONBLOCK)
    func recvLine() -> String {
        var out = ""; var buf = [UInt8](repeating: 0, count: 1024)
        while !out.contains("\n") { let n = recv(conn, &buf, buf.count, 0); if n <= 0 { break }; out += String(decoding: buf[0..<n], as: UTF8.self) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let hello = recvLine(); errln(">>> device: \(hello)")
    let line = "\(token) \(cmd)\n"; _ = line.withCString { send(conn, $0, strlen($0), 0) }
    print(recvLine())   // reply → stdout for the harness
    close(conn); close(ls); exit(0)
}

// Check (and, if off, reveal) Developer Mode on connected devices.
if let i = args.firstIndex(of: "--devmode") {
    let udids: [String]
    if i + 1 < args.count, !args[i + 1].hasPrefix("-") { udids = [args[i + 1]] }
    else { udids = Sideloader.connectedDevices().map { $0.udid } }
    if udids.isEmpty { errln(">>> no connected devices") }
    for u in udids {
        let m = Sideloader.developerMode(u)
        errln(">>> \(u): Developer Mode \(m)")
        if m == .disabled {
            Sideloader.revealDeveloperMode(u)
            errln(">>> \(Sideloader.developerModeHelp)")
        }
    }
    exit(0)
}

if args.contains("--listen") {
    BeaconListener.shared.start(log: { errln("· \($0)") })
    errln(">>> beacon listener running on udp/\(BeaconListener.port) — open an instrumented app on the device")
    RunLoop.main.run()
}

if args.contains("--refresh") {
    Task {
        do { try await Sideloader.refreshAll(log: { errln("· \($0)") }); errln(">>> refresh done") }
        catch { errln(">>> refresh FAILED: \(error)") }
        sem.signal()
    }
    sem.wait(); exit(0)
}

// Install an arbitrary local .app (used for the beacon; pairs with IWISH_IP).
if let i = args.firstIndex(of: "--app"), i + 1 < args.count {
    let appPath = args[i + 1]
    withSaved { account, session in
        do { errln(">>> " + (try await Sideloader.install(account: account, session: session, appPath: appPath, source: appPath, iPadUDID: udid, log: { errln("· \($0)") }))) }
        catch { errln(">>> FAILED: \(error)") }
    }
    exit(0)
}

if args.contains("--install") {
    withSaved { account, session in
        do { errln(">>> " + (try await Sideloader.install(account: account, session: session, appPath: localIWish, source: localIWish, iPadUDID: udid, log: { errln("· \($0)") }))) }
        catch { errln(">>> FAILED: \(error)") }
    }
    exit(0)
}

// Uninstall a tracked app by bundle id (exercises SideStep's own removeApp path:
// device uninstall + App-ID cleanup + untrack). Used by the regression suite.
if let i = args.firstIndex(of: "--uninstall"), i + 1 < args.count {
    let bid = args[i + 1]
    withSaved { _, _ in
        if let t = Tracked.all().first(where: { $0.installedBundleID == bid || $0.origBundleID == bid }) {
            await Sideloader.removeApp(t, log: { errln("· \($0)") })
            errln(">>> UNINSTALL OK \(bid)")
        } else {
            errln(">>> UNINSTALL FAILED: \(bid) not tracked")
        }
    }
    exit(0)
}

// Reinstall a tracked app from its source (GitHub/http/file), re-injecting the CURRENT
// beacon — used to push a new beacon build onto an existing install.
if let i = args.firstIndex(of: "--refresh-one"), i + 1 < args.count {
    let bid = args[i + 1]
    withSaved { _, _ in
        guard let t = Tracked.all().first(where: { $0.installedBundleID == bid || $0.origBundleID == bid }) else {
            errln(">>> REFRESH FAILED: \(bid) not tracked"); return
        }
        do { errln(">>> " + (try await Sideloader.refreshOne(t, log: { errln("· \($0)") }))) }
        catch { errln(">>> REFRESH FAILED: \(error)") }
    }
    exit(0)
}

if let i = args.firstIndex(of: "--source"), i + 1 < args.count {
    let url = args[i + 1]
    let bid = (i + 2 < args.count) ? args[i + 2] : ""
    withSaved { account, session in
        do { errln(">>> " + (try await Sideloader.installFromSource(account: account, session: session, sourceURL: url, bundleIdentifier: bid, iPadUDID: udid, log: { errln("· \($0)") }))) }
        catch { errln(">>> FAILED: \(error)") }
    }
    exit(0)
}

// ---- auth mode ----
guard args.count >= 2 else { errln("usage: Provision --install | --source <url> [bundleID] | --refresh | <apple-id> [--sms]"); exit(64) }
let appleID = args[1]
ALTAppleAPI.preferSMSTwoFactorCode = args.contains("--sms")
guard let anisette = Anisette.fresh() else { errln("Anisette generation failed"); exit(1) }
let pw: String
if let envpw = ProcessInfo.processInfo.environment["SIDESTEP_PW"], !envpw.isEmpty { pw = envpw }
else { pw = String(cString: getpass("Apple ID password (no echo): ")) }
guard !pw.isEmpty else { errln("no password"); exit(1) }

ALTAppleAPI.sharedAPI.authenticate(
    appleID: appleID, password: pw, anisetteData: anisette,
    verificationHandler: { submit in
        if let code = ProcessInfo.processInfo.environment["SIDESTEP_2FA"], !code.isEmpty { submit(code) }
        else { FileHandle.standardError.write(Data("2FA code: ".utf8)); submit(readLine()?.trimmingCharacters(in: .whitespaces)) }
    },
    completionHandler: { account, session, error in
        if let error { errln(">>> AUTH FAILED: \(error)"); sem.signal(); return }
        guard let account, let session else { errln(">>> AUTH FAILED: no account"); sem.signal(); return }
        AccountStore.add(account: account, session: session)
        Keychain.savePassword(pw, for: account.appleID)
        errln(">>> AUTH OK: \(account.appleID) (account + keychain saved)")
        sem.signal()
    })
sem.wait()
