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
