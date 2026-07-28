// Provision / iSideload CLI.
//   Provision --install                  reuse saved session → install iWish (local build)
//   Provision --source <url> [bundleID]  reuse saved session → install app from an AltStore source
//   Provision --refresh                  re-sign+reinstall every tracked app (used by the LaunchAgent)
//   Provision <apple-id> [--sms]         authenticate (env ISIDELOAD_PW / ISIDELOAD_2FA) + save session
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
        errln("No saved account — sign in via the iSideload app once first."); exit(1)
    }
    errln(">>> account \(account.appleID)")
    Task { await work(account, session); sem.signal() }
    sem.wait()
}

if let i = args.firstIndex(of: "--inspect"), i + 1 < args.count {
    let info = IPAInspector.inspect(args[i + 1])
    print("name=\(info.appName)  bundleID=\(info.bundleID)  version=\(info.version)")
    print("signer=\(info.signer.rawValue)  otaCapable=\(info.otaCapable)")
    exit(0)
}

if let i = args.firstIndex(of: "--ota"), i + 1 < args.count {
    let info = IPAInspector.inspect(args[i + 1])
    OTAHost.shared.onProgress = { stage, sent, total in
        if stage == "downloading" { errln(">>> progress \(stage) \(sent)/\(total) (\(total > 0 ? Int(Double(sent)/Double(total)*100) : 0)%)") }
        else { errln(">>> progress \(stage)") }
    }
    do {
        let url = try OTAHost.shared.start(ipaPath: args[i + 1], info: info)
        errln(">>> OTA host serving \(url)  (\(info.appName), \(info.signer.rawValue))")
        RunLoop.main.run()
    } catch { errln(">>> OTA host failed: \(error)"); exit(1) }
}

if args.contains("--getudid") {
    OTAHost.shared.onUDID = { udid, product, version in
        errln(">>> UDID CAPTURED: \(udid)  product=\(product) version=\(version)")
    }
    do {
        let url = try OTAHost.shared.startUDIDCapture()
        errln(">>> UDID host serving \(url)  (open on the device, install the profile)")
        RunLoop.main.run()
    } catch { errln(">>> UDID host failed: \(error)"); exit(1) }
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
if let envpw = ProcessInfo.processInfo.environment["ISIDELOAD_PW"], !envpw.isEmpty { pw = envpw }
else { pw = String(cString: getpass("Apple ID password (no echo): ")) }
guard !pw.isEmpty else { errln("no password"); exit(1) }

ALTAppleAPI.sharedAPI.authenticate(
    appleID: appleID, password: pw, anisetteData: anisette,
    verificationHandler: { submit in
        if let code = ProcessInfo.processInfo.environment["ISIDELOAD_2FA"], !code.isEmpty { submit(code) }
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
