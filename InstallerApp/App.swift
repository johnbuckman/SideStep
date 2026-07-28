// iSideload — lean-AltServer macOS app.
// Multiple Apple accounts (each free ID = 3 app slots), install from an AltStore
// source URL or a local .ipa/.app, pick which account + which connected device.
import SwiftUI
import AltSign
import SwiftBridge
import SideloaderKit
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Foundation
import CoreImage

// In-app refresh scheduler — replaces the external LaunchAgents. Runs while the
// app is alive in the menu bar: refreshes on device-connect and on a ~2h timer
// (refreshAll is itself expiry-aware + single-flight-locked, so this is cheap).
final class RefreshDaemon {
    static let shared = RefreshDaemon()
    private let q = DispatchQueue(label: "com.decent.isideload.refresh")
    private var seen = Set<String>()
    private var started = false
    private var tickCount = 0

    func start() {
        guard !started else { return }
        started = true
        q.async { [weak self] in
            while true {
                self?.tick()
                Thread.sleep(forTimeInterval: 25)
            }
        }
    }
    private func tick() {
        tickCount += 1
        let devices = Set(Sideloader.connectedDevices().map { $0.udid })   // USB + WiFi-reachable
        let newlyConnected = !devices.subtracting(seen).isEmpty
        seen = devices

        // "Urgent" = an app past 70% of its signing window whose device is reachable right now.
        // Free profiles die at 7 days and only install to an UNLOCKED device, so near expiry we
        // poll every 5 minutes and push the moment the device is reachable (USB or WiFi/unlocked).
        let now = Date().timeIntervalSince1970
        let urgentReachable = Tracked.all().contains { t in
            guard let li = t.lastInstalled else { return false }
            let past70 = (now - li) > 0.7 * Double(t.validityDays) * 86400
            return past70 && devices.contains(t.udid)
        }
        let fiveMinTick = (tickCount % 12 == 0)   // 25s × 12 ≈ 5 min

        if (newlyConnected && !devices.isEmpty) || (fiveMinTick && urgentReachable) {
            Task { try? await Sideloader.refreshAll(log: { print("[iSideload refresh] \($0)") }) }
        }
    }
}

let iSideloadLogPath = (("~/Library/Logs/iSideload.log") as NSString).expandingTildeInPath
func installDiagnosticsLog() {
    setvbuf(stdout, nil, _IONBF, 0); setvbuf(stderr, nil, _IONBF, 0)
    // Tee stdout+stderr → the on-screen debug log AND the file, so nothing is silent.
    let fm = FileManager.default
    if !fm.fileExists(atPath: iSideloadLogPath) {
        try? fm.createDirectory(atPath: (iSideloadLogPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: iSideloadLogPath, contents: nil)
    }
    guard let logFH = FileHandle(forWritingAtPath: iSideloadLogPath) else {
        AltSignLogging.setLogging(true); return
    }
    logFH.seekToEndOfFile()
    let pipe = Pipe()
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    pipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        guard !d.isEmpty else { return }
        try? logFH.write(contentsOf: d)
        DebugLog.shared.write(d)
    }
    AltSignLogging.setLogging(true)
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    print("\n=== iSideload \(v) launched \(Date()) ===")
    dlog("macOS \(ProcessInfo.processInfo.operatingSystemVersionString); bundle \(Bundle.main.bundleURL.path)")
}

struct DeviceOption: Identifiable { let udid: String; let name: String; var id: String { udid } }
enum InstallKind { case ipa(String), source(SourceApp) }

/// Enables only .ipa / .app in the open panel, plus plain folders so the user
/// can still navigate. Extension-based so it does not depend on LaunchServices
/// having classified a file as the dynamic "ipa" UTType.
final class IPAPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "ipa" || ext == "app" { return true }
        let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        // plain (non-package) directories stay selectable so navigation works
        return (vals?.isDirectory ?? false) && !(vals?.isPackage ?? false)
    }
}

@MainActor final class AppModel: ObservableObject {
    // accounts
    @Published var accounts: [AccountRecord] = AccountStore.records()
    @Published var tracked: [TrackedApp] = Tracked.all()
    @Published var addingAccount = false

    // login form
    @Published var appleID = ""
    @Published var password = ""
    @Published var code = ""
    @Published var textMeCode = false
    enum LoginStage: Equatable { case idle, working, needs2FA }
    @Published var loginStage: LoginStage = .idle
    @Published var loginStatus = ""
    private var submit2FA: ((String?) -> Void)?

    // install
    @Published var installing = false
    @Published var status = ""
    @Published var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @Published var sourceURL = ""
    @Published var sourceApps: [SourceApp] = []

    // pickers
    @Published var showAccountPicker = false
    @Published var showDevicePicker = false
    @Published var deviceOptions: [DeviceOption] = []
    private var pendingKind: InstallKind?
    private var chosenAppleID: String?

    // MARK: accounts

    func login() {
        guard !appleID.isEmpty, !password.isEmpty else { loginStatus = "Enter Apple ID and password."; return }
        ALTAppleAPI.preferSMSTwoFactorCode = textMeCode
        loginStage = .working; loginStatus = "Signing in…"
        let id = appleID, pw = password
        DispatchQueue.global().async {
            guard let anisette = Anisette.fresh() else { Task { @MainActor in self.loginStatus = "Anisette failed."; self.loginStage = .idle }; return }
            ALTAppleAPI.sharedAPI.authenticate(appleID: id, password: pw, anisetteData: anisette,
                verificationHandler: { submit in Task { @MainActor in self.submit2FA = submit; self.loginStage = .needs2FA; self.loginStatus = "Enter the 2-factor code." } },
                completionHandler: { account, session, error in
                    Task { @MainActor in
                        if let error {
                            let ns = error as NSError
                            self.loginStatus = "Sign-in failed: \(error.localizedDescription) [\(ns.code)]"; self.loginStage = .idle
                        } else if let account, let session {
                            AccountStore.add(account: account, session: session)
                            Keychain.savePassword(pw, for: account.appleID)
                            self.accounts = AccountStore.records()
                            self.appleID = ""; self.password = ""; self.code = ""; self.textMeCode = false
                            self.loginStage = .idle; self.loginStatus = ""; self.addingAccount = false
                            self.status = "Added \(account.appleID)."
                            Task.detached {
                                let teams = await Sideloader.fetchTeamInfos(account: account, session: session)
                                await MainActor.run {
                                    AccountStore.setTeams(account.appleID, teams)
                                    self.accounts = AccountStore.records()
                                    if teams.count > 1, AccountStore.chosenTeamID(for: account.appleID) == nil {
                                        self.status = "\(account.appleID): pick a team below (free = 7 days, paid = 1 year)."
                                    }
                                }
                            }
                        }
                    }
                })
        }
    }
    func submitCode() {
        guard let submit = submit2FA else { return }
        loginStage = .working; loginStatus = "Verifying…"
        let c = code.trimmingCharacters(in: .whitespaces); submit2FA = nil
        DispatchQueue.global().async { submit(c) }
    }
    func cancelLogin() { addingAccount = false; loginStage = .idle; loginStatus = ""; password = ""; code = "" }
    func removeAccount(_ id: String) { AccountStore.remove(id); accounts = AccountStore.records() }

    // MARK: source

    func loadSource() {
        let url = sourceURL; status = "Loading source…"
        Task { @MainActor in
            do { sourceApps = try await Sideloader.fetchSource(url); status = "\(sourceApps.count) app(s) available." }
            catch { status = "Couldn't load source: \(error.localizedDescription)" }
        }
    }
    /// Keeps the open-panel delegate alive for the duration of the panel
    /// (NSOpenPanel.delegate is weak).
    private var ipaPanelDelegate: IPAPanelDelegate?

    func pickIPA() {
        // No content-type filter and no enabling-delegate: BOTH make macOS grey
        // out .ipa files until the directory is re-enumerated (the "navigate away
        // and come back" bug). Allow everything, then validate the choice.
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true            // so .app bundles are selectable
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Install"
        dlog("pickIPA: opening file panel")
        guard panel.runModal() == .OK, let url = panel.url else { dlog("pickIPA: cancelled"); return }
        let ext = url.pathExtension.lowercased()
        dlog("pickIPA: chose \(url.path) (ext=\(ext))")
        if ext == "ipa" || ext == "app" { openIPA(url.path) }
        else { status = "Please choose an .ipa file or a .app bundle."; dlog("pickIPA: rejected — not .ipa/.app") }
    }
    func pickJSON() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if let json = UTType(filenameExtension: "json") { panel.allowedContentTypes = [json] }
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        do {
            let apps = try Sideloader.loadSourceFile(u.path)
            sourceApps = apps
            if apps.count == 1 { startInstall(.source(apps[0])) }
            else { status = "\(apps.count) app(s) from \(u.lastPathComponent) — pick one below." }
        } catch { status = "Couldn't read source: \(error.localizedDescription)" }
    }

    // MARK: install (resolve account → device → run)

    func startInstall(_ kind: InstallKind) {
        dlog("startInstall: kind=\(kind), accounts=\(accounts.count)")
        guard !accounts.isEmpty else { status = "Add an Apple account first."; addingAccount = true; dlog("startInstall: no accounts"); return }
        pendingKind = kind; chosenAppleID = nil
        if accounts.count == 1 {
            guard okToInstall(accounts[0]) else { dlog("startInstall: blocked — team not chosen for \(accounts[0].appleID)"); return }
            chosenAppleID = accounts[0].appleID; resolveDevice()
        } else { dlog("startInstall: multiple accounts — showing picker"); showAccountPicker = true }
    }
    func chooseAccount(_ id: String) {
        showAccountPicker = false
        guard let acc = accounts.first(where: { $0.appleID == id }), okToInstall(acc) else { return }
        chosenAppleID = id; resolveDevice()
    }
    /// Block an install on a multi-team account until the user has chosen which team to sign with.
    private func okToInstall(_ acc: AccountRecord) -> Bool {
        if acc.needsTeamChoice { status = "Pick a team for \(acc.appleID) first (free = 7 days, paid = 1 year)."; return false }
        return true
    }
    private func resolveDevice() {
        status = "Looking for a connected device…"
        dlog("resolveDevice: enumerating connected devices…")
        Task.detached {
            let devs = Sideloader.connectedDevices().map { DeviceOption(udid: $0.udid, name: $0.name) }
            dlog("resolveDevice: found \(devs.count) device(s): \(devs.map { "\($0.name)=\($0.udid)" }.joined(separator: ", "))")
            await MainActor.run {
                if devs.isEmpty { self.status = "No iOS device connected. Plug in and unlock it, then try again." }
                else if devs.count == 1 { self.execute(udid: devs[0].udid) }
                else { self.deviceOptions = devs; self.showDevicePicker = true }
            }
        }
    }
    func chooseDevice(_ udid: String) { showDevicePicker = false; execute(udid: udid) }

    private func execute(udid: String) {
        dlog("execute: udid=\(udid) appleID=\(chosenAppleID ?? "nil") kind=\(pendingKind.map { "\($0)" } ?? "nil")")
        guard let kind = pendingKind, let aid = chosenAppleID,
              let (account, session) = AccountStore.session(for: aid) else {
            status = "Couldn't load that account."
            dlog("execute: ABORT — pendingKind/chosenAppleID/session missing (session for \(chosenAppleID ?? "nil") = \(chosenAppleID.flatMap { AccountStore.session(for: $0) } == nil ? "nil" : "ok"))")
            return
        }
        installing = true; status = "Installing…"
        dlog("execute: starting install task for \(account.appleID)")
        Task.detached { [weak self] in
            guard let self else { return }
            let log: @Sendable (String) -> Void = { msg in print("[iSideload] \(msg)"); Task { @MainActor in self.status = String(msg.split(separator: "\n").first.map(String.init)?.prefix(160) ?? "") } }
            do {
                let result: String
                switch kind {
                case .ipa(let path): result = try await Sideloader.installFromIPA(account: account, session: session, filePath: path, iPadUDID: udid, log: log)
                case .source(let app): result = try await Sideloader.installSourceApp(account: account, session: session, app: app, iPadUDID: udid, log: log)
                }
                dlog("execute: install SUCCEEDED — \(result)")
                await MainActor.run { self.status = result }
            } catch {
                dlog("execute: INSTALL FAILED — \(String(reflecting: error))")
                await MainActor.run { self.status = "Failed: \(error.localizedDescription)" }
            }
            await MainActor.run { self.tracked = Tracked.all(); self.installing = false }
        }
    }

    // MARK: IPA routing — USB vs QR/over-the-air (and IPA file open)

    static let shared = AppModel()
    private var qrWindow: NSWindow?
    private var udidWindow: NSWindow?

    /// Entry point for a picked or double-clicked `.ipa`: inspect it, then offer the right
    /// install path. Ad-hoc/enterprise-signed → USB **or** QR (over the air). Development-
    /// signed → USB only, with the Developer-Mode + trust steps the user will need.
    func openIPA(_ path: String) {
        dlog("openIPA: inspecting \(path)")
        let info = IPAInspector.inspect(path)
        dlog("openIPA: appName=\(info.appName) bundleID=\(info.bundleID) signer=\(info.signer) otaCapable=\(info.otaCapable)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install “\(info.appName)”?"
        if info.otaCapable {
            alert.informativeText = "This app is \(info.signer == .enterprise ? "enterprise" : "ad-hoc")-signed, so it can install over the air. Show a QR code to scan on your device — or install over USB.\(info.signer == .enterprise ? "" : " First time on a device, the user enables Developer Mode (Settings ▸ Privacy & Security ▸ Developer Mode).")"
            alert.addButton(withTitle: "Show QR code (over the air)")
            alert.addButton(withTitle: "Install via USB")
            alert.addButton(withTitle: "Cancel")
            let r = alert.runModal()
            dlog("openIPA: OTA-capable alert → \(r == .alertFirstButtonReturn ? "QR" : r == .alertSecondButtonReturn ? "USB" : "Cancel")")
            switch r {
            case .alertFirstButtonReturn:  startOTA(path: path, info: info)
            case .alertSecondButtonReturn: startInstall(.ipa(path))
            default: break
            }
        } else {
            alert.informativeText = """
            This app is development-signed, so it installs over USB. On the device you'll then:
            1.  Enable Developer Mode — Settings ▸ Privacy & Security ▸ Developer Mode (the device restarts).
            2.  Trust the developer — Settings ▸ General ▸ VPN & Device Management ▸ tap the Apple ID ▸ Trust.
            It re-signs every 7 days (or yearly if the account is a paid $99 Apple ID).
            """
            alert.addButton(withTitle: "Install via USB")
            alert.addButton(withTitle: "Cancel")
            let r = alert.runModal()
            dlog("openIPA: dev-signed alert → \(r == .alertFirstButtonReturn ? "USB" : "Cancel")")
            if r == .alertFirstButtonReturn { startInstall(.ipa(path)) }
        }
    }

    private func startOTA(path: String, info: IPAInfo) {
        status = "Preparing over-the-air install…"
        OTAProgress.shared.reset()
        OTAHost.shared.onProgress = { stage, sent, total in
            Task { @MainActor in
                let p = OTAProgress.shared; p.stage = stage; p.sent = sent; p.total = total
            }
        }
        Task.detached { [weak self] in
            do {
                let url = try OTAHost.shared.start(ipaPath: path, info: info)
                await MainActor.run { self?.showQR(url: url, info: info); self?.status = "Scan the QR code on your iOS device." }
            } catch {
                await MainActor.run {
                    self?.status = "Couldn't start the QR host."
                    let a = NSAlert()
                    a.messageText = "Couldn't start the over-the-air install"
                    a.informativeText = error.localizedDescription
                    a.alertStyle = .warning
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                }
            }
        }
    }

    func qrImage(_ string: String, size: CGFloat = 300) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(string.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: size / ci.extent.width, y: size / ci.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }

    private func showQR(url: URL, info: IPAInfo) {
        let host = NSHostingView(rootView: QRView(url: url, appName: info.appName))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Install \(info.appName) over Wi-Fi"
        win.contentView = host; win.center(); win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        qrWindow = win
    }

    func closeQR() { OTAHost.shared.onProgress = nil; OTAHost.shared.stop(); OTAProgress.shared.reset(); qrWindow?.close(); qrWindow = nil; if status.hasPrefix("Scan") { status = "" } }

    // MARK: capture a device UDID over Wi-Fi (Profile Service)
    func captureUDID() {
        status = "Starting device registration…"
        UDIDCapture.shared.reset()
        OTAHost.shared.onUDID = { udid, product, version in
            Task { @MainActor in
                let c = UDIDCapture.shared; c.udid = udid; c.product = product; c.version = version
            }
        }
        Task.detached { [weak self] in
            do {
                let url = try OTAHost.shared.startUDIDCapture()
                await MainActor.run { UDIDCapture.shared.url = url; self?.showUDIDWindow(url: url); self?.status = "Open the link on the device, then install the profile." }
            } catch {
                await MainActor.run {
                    self?.status = ""
                    let a = NSAlert(); a.messageText = "Couldn't start device registration"; a.informativeText = error.localizedDescription
                    a.alertStyle = .warning; NSApp.activate(ignoringOtherApps: true); a.runModal()
                }
            }
        }
    }
    private func showUDIDWindow(url: URL) {
        let host = NSHostingView(rootView: UDIDCaptureView(url: url))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Register a device over Wi-Fi"
        win.contentView = host; win.center(); win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        udidWindow = win
    }
    func closeUDIDCapture() { OTAHost.shared.onUDID = nil; OTAHost.shared.stop(); UDIDCapture.shared.reset(); udidWindow?.close(); udidWindow = nil; if status.hasPrefix("Open the link") { status = "" } }

    // MARK: installed-apps management

    func loadAccountInfo() {
        for acc in accounts where acc.teams.isEmpty { refreshTeams(for: acc.appleID) }
    }
    /// (Re)fetch the list of teams an account belongs to, so the Team menu is populated.
    func refreshTeams(for appleID: String) {
        guard let (a, s) = AccountStore.session(for: appleID) else { return }
        Task.detached {
            let teams = await Sideloader.fetchTeamInfos(account: a, session: s)
            guard !teams.isEmpty else { return }
            await MainActor.run { AccountStore.setTeams(appleID, teams); self.accounts = AccountStore.records() }
        }
    }
    /// User picked which team to sign this account's apps with.
    func chooseTeam(_ appleID: String, _ teamID: String) {
        AccountStore.chooseTeam(appleID, id: teamID)
        accounts = AccountStore.records()
        status = "\(appleID): signing with \(accounts.first { $0.appleID == appleID }?.teamName ?? "team")."
    }

    func expiryText(_ t: TrackedApp) -> String {
        guard let s = t.secondsUntilExpiry else { return "expiry unknown" }
        if s <= 0 { return "EXPIRED" }
        let days = Int(s / 86400)
        return days >= 1 ? "expires in \(days) day\(days == 1 ? "" : "s")" : "expires in <1 day"
    }

    func deviceIcon(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("iphone") { return "iphone" }
        if l.contains("ipod") { return "ipodtouch" }
        return "ipad"   // default (covers iPads and unknown UDIDs)
    }

    /// The account's apps grouped by app, each with the device(s) it's installed on.
    func appsGrouped(_ appleID: String) -> [(key: String, name: String, devices: [TrackedApp])] {
        let g = Dictionary(grouping: tracked.filter { $0.appleID == appleID }, by: { $0.origBundleID })
        return g.keys.sorted().map { k in
            (key: k, name: g[k]!.first!.name, devices: g[k]!.sorted { $0.udid < $1.udid })
        }
    }

    func refreshApp(_ t: TrackedApp) {
        installing = true; status = "Refreshing \(t.name) on \(t.deviceName.isEmpty ? "device" : t.deviceName)…"
        Task.detached { [weak self] in
            guard let self else { return }
            let log: @Sendable (String) -> Void = { m in print("[iSideload] \(m)"); Task { @MainActor in self.status = String(m.split(separator: "\n").first.map(String.init)?.prefix(160) ?? "") } }
            do { let r = try await Sideloader.refreshOne(t, log: log); await MainActor.run { self.status = r } }
            catch { await MainActor.run { self.status = "Refresh failed: \(error.localizedDescription)" } }
            await MainActor.run { self.tracked = Tracked.all(); self.installing = false }
        }
    }

    func removeApp(_ t: TrackedApp) {
        installing = true; status = "Removing \(t.name)…"
        Task.detached { [weak self] in
            guard let self else { return }
            let log: @Sendable (String) -> Void = { m in print("[iSideload] \(m)"); Task { @MainActor in self.status = String(m.prefix(160)) } }
            await Sideloader.removeApp(t, log: log)
            await MainActor.run { self.tracked = Tracked.all(); self.status = "Removed \(t.name)."; self.installing = false }
        }
    }

    // MARK: settings

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Couldn't change login item: \(error.localizedDescription)"
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func refreshAllNow() {
        installing = true; status = "Refreshing all apps…"
        Task.detached { [weak self] in
            guard let self else { return }
            let log: @Sendable (String) -> Void = { m in print("[iSideload] \(m)"); Task { @MainActor in self.status = String(m.split(separator: "\n").first.map(String.init)?.prefix(160) ?? "") } }
            do { try await Sideloader.refreshAll(log: log); await MainActor.run { self.status = "Refreshed." } }
            catch { await MainActor.run { self.status = "Refresh failed: \(error.localizedDescription)" } }
            await MainActor.run { self.tracked = Tracked.all(); self.installing = false }
        }
    }
}

// ── UI ──

/// The over-the-air install window: a QR code the user scans on their iPhone/iPad.
/// Live download progress the Mac shows under the QR code. Fed by OTAHost.onProgress.
@MainActor final class OTAProgress: ObservableObject {
    static let shared = OTAProgress()
    @Published var stage = "waiting"
    @Published var sent: Int64 = 0
    @Published var total: Int64 = 0
    var fraction: Double { total > 0 ? min(1, Double(sent) / Double(total)) : 0 }
    func reset() { stage = "waiting"; sent = 0; total = 0 }
    static func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
    var label: String {
        switch stage {
        case "confirmed":   return "Install confirmed — starting download…"
        case "downloading": return "Downloading to your device…"
        case "downloaded":  return "Download complete — installing on your device…"
        default:            return "Waiting for you to tap Install on your device…"
        }
    }
}

/// Captured device identity from the Profile Service enrollment.
@MainActor final class UDIDCapture: ObservableObject {
    static let shared = UDIDCapture()
    @Published var url: URL?
    @Published var udid = ""
    @Published var product = ""
    @Published var version = ""
    func reset() { url = nil; udid = ""; product = ""; version = "" }
}

/// Window that shows a QR/link to register a device and, once it reports in, its UDID.
struct UDIDCaptureView: View {
    let url: URL
    @ObservedObject private var c = UDIDCapture.shared
    var body: some View {
        VStack(spacing: 14) {
            Text("Register a device").font(.title2.bold())
            if c.udid.isEmpty {
                Text("On the iPhone or iPad, scan this (or open the link) and install the profile it offers.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if let img = AppModel.shared.qrImage(url.absoluteString) {
                    Image(nsImage: img).interpolation(.none).resizable()
                        .frame(width: 250, height: 250).padding(10).background(Color.white).cornerRadius(8)
                }
                Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Text("Then on the device: **Settings ▸ Profile Downloaded** (or **General ▸ VPN & Device Management**) ▸ **Install** ▸ passcode.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for the device…").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("Device registered ✓").font(.headline).foregroundStyle(.green)
                if !c.product.isEmpty { Text("\(c.product)\(c.version.isEmpty ? "" : " · iOS \(c.version)")").font(.caption).foregroundStyle(.secondary) }
                GroupBox {
                    HStack {
                        Text(c.udid).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.udid, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy UDID")
                    }.padding(6)
                }
                Text("Give me this UDID and I can register it with Apple and re-sign your apps for it.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Button("Done") { AppModel.shared.closeUDIDCapture() }.keyboardShortcut(.defaultAction)
        }.padding(22).frame(width: 420)
    }
}

struct QRView: View {
    let url: URL
    let appName: String
    @ObservedObject private var prog = OTAProgress.shared
    var body: some View {
        VStack(spacing: 14) {
            Text(appName).font(.title2.bold())
            Text("Scan with your iPhone or iPad camera").font(.callout).foregroundStyle(.secondary)
            if let img = AppModel.shared.qrImage(url.absoluteString) {
                Image(nsImage: img).interpolation(.none).resizable()
                    .frame(width: 280, height: 280)
                    .padding(10).background(Color.white).cornerRadius(8)
            }
            Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Text("Then tap **Install** on your device. First time on a device: enable **Settings ▸ Privacy & Security ▸ Developer Mode** (it restarts once). Keep iSideload open until it finishes.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Live progress, driven by the host serving the IPA.
            VStack(spacing: 6) {
                Text(prog.label)
                    .font(.callout)
                    .foregroundStyle(prog.stage == "downloaded" ? Color.green : Color.secondary)
                if prog.total > 0 && (prog.stage == "downloading" || prog.stage == "downloaded") {
                    ProgressView(value: prog.fraction).frame(width: 300)
                    Text("\(OTAProgress.mb(prog.sent)) / \(OTAProgress.mb(prog.total))  (\(Int(prog.fraction * 100))%)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }.padding(.top, 2)
            Button("Done") { AppModel.shared.closeQR() }.keyboardShortcut(.defaultAction)
        }.padding(22).frame(width: 420)
    }
}

struct ContentView: View {
    @ObservedObject private var m = AppModel.shared
    @State private var accountsExpanded = true
    @State private var installExpanded = true
    @State private var collapsedAccounts = Set<String>()   // ids stored when COLLAPSED (default expanded)
    @State private var collapsedApps = Set<String>()

    private func accBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !collapsedAccounts.contains(id) },
                set: { collapsedAccounts = $0 ? collapsedAccounts.subtracting([id]) : collapsedAccounts.union([id]) })
    }
    private func appBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !collapsedApps.contains(id) },
                set: { collapsedApps = $0 ? collapsedApps.subtracting([id]) : collapsedApps.union([id]) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iSideload").font(.title2).bold()
            Text("Create free Apple accounts at [icloud.com](https://www.icloud.com/) — each free account can install **3 apps**. A $99/year Apple Developer subscription removes the limit.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            // Accounts + their installed apps
            DisclosureGroup("Your Apple accounts", isExpanded: $accountsExpanded) {
              VStack(alignment: .leading, spacing: 8) {
            if m.accounts.isEmpty { Text("No accounts yet — add one below.").font(.caption).foregroundStyle(.secondary) }
            ForEach(m.accounts) { acc in
                let used = m.tracked.filter { $0.appleID == acc.appleID }.count
                DisclosureGroup(isExpanded: accBinding(acc.appleID)) {
                    VStack(alignment: .leading, spacing: 4) {  // FirstLineDisclosureStyle: chevron on the name line
                        ForEach(m.appsGrouped(acc.appleID), id: \.key) { grp in
                            DisclosureGroup(isExpanded: appBinding("\(acc.appleID)/\(grp.key)")) {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(grp.devices) { t in
                                        let devLabel = t.deviceName.isEmpty ? t.udid : t.deviceName
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: m.deviceIcon(devLabel)).frame(width: 20).foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 0) {
                                                Text(devLabel).font(.callout)
                                                Text(m.expiryText(t)).font(.caption2)
                                                    .foregroundStyle((t.secondsUntilExpiry ?? 1) <= 0 ? .red : .secondary)
                                            }
                                            Spacer()
                                            Button { m.refreshApp(t) } label: { Image(systemName: "arrow.clockwise") }
                                                .buttonStyle(.borderless).help("Re-sign & reinstall on this device").disabled(m.installing)
                                            Button { m.removeApp(t) } label: { Image(systemName: "minus.circle") }
                                                .buttonStyle(.borderless).help("Uninstall & free the slot").disabled(m.installing)
                                        }
                                        .padding(.leading, 42)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.grid.2x2.fill").frame(width: 20).foregroundStyle(.secondary)
                                    Text(grp.name).font(.callout)
                                }
                            }
                        }
                    }.padding(.leading, 26)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "person.crop.circle").frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(acc.displayName).font(.callout)
                            HStack(spacing: 6) {
                                if !acc.validity.isEmpty { Text(acc.validity).foregroundStyle(acc.isPaid ? .green : .secondary) }
                                if !acc.isPaid && acc.teamChosen { Text("slots \(used)/3").foregroundStyle(used >= 3 ? .orange : .secondary) }
                            }.font(.caption2)
                            if acc.teams.count > 1 {
                                TeamMenu(acc: acc) { m.chooseTeam(acc.appleID, $0) }
                            }
                        }
                        Spacer()
                        Button { m.removeAccount(acc.appleID) } label: { Image(systemName: "person.badge.minus") }
                            .buttonStyle(.borderless).help("Remove this account")
                    }
                }
                .disclosureGroupStyle(FirstLineDisclosureStyle())
            }

            if m.addingAccount || m.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Apple ID (email)", text: $m.appleID).textFieldStyle(.roundedBorder).disabled(m.loginStage == .working)
                    SecureField("Password", text: $m.password).textFieldStyle(.roundedBorder).disabled(m.loginStage == .working).onSubmit { m.login() }
                    Toggle("Text me the code (no Apple device signed into this account)", isOn: $m.textMeCode).font(.caption).disabled(m.loginStage == .working)
                    if m.loginStage == .needs2FA {
                        HStack {
                            TextField("2-factor code", text: $m.code).textFieldStyle(.roundedBorder).frame(width: 130).onSubmit { m.submitCode() }
                            Button("Verify") { m.submitCode() }.keyboardShortcut(.defaultAction)
                        }
                    }
                    HStack {
                        Button("Sign in") { m.login() }.keyboardShortcut(.defaultAction).disabled(m.loginStage != .idle)
                        if !m.accounts.isEmpty { Button("Cancel") { m.cancelLogin() } }
                        if m.loginStage == .working { ProgressView().scaleEffect(0.6).frame(width: 14, height: 14) }
                        Text(m.loginStatus).font(.caption).foregroundStyle(.red)
                    }
                }.padding(.leading, 4)
            } else {
                Button { m.addingAccount = true } label: { Label("Add account", systemImage: "plus.circle") }.buttonStyle(.borderless)
            }
              }
            }.font(.headline)

            if !m.accounts.isEmpty {
                Divider()
                DisclosureGroup("Install", isExpanded: $installExpanded) {
                  VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Source URL (AltStore repo)", text: $m.sourceURL).textFieldStyle(.roundedBorder)
                    Button("Load") { m.loadSource() }.disabled(m.installing)
                }
                ForEach(m.sourceApps) { app in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.callout)
                            if let v = app.version { Text("v\(v)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Install") { m.startInstall(.source(app)) }.disabled(m.installing)
                    }
                }
                HStack {
                    Button("Install from .json…") { m.pickJSON() }.disabled(m.installing)
                    Button("Install from .ipa…") { m.pickIPA() }.disabled(m.installing)
                    Button("Register a device over Wi-Fi…") { m.captureUDID() }.disabled(m.installing)
                }
                  }
                }.font(.headline)
            }

            Divider()
            DisclosureGroup("Settings") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Launch iSideload at login (keeps apps auto-refreshed)", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
                    Button("Refresh all apps now") { m.refreshAllNow() }.disabled(m.installing)
                    Button("Show Debug Log…") { DebugWindow.show() }
                    Text("iSideload keeps apps signed while it runs in the menu bar — it re-signs automatically when you plug in a device and every couple of hours. No separate background program is needed.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 2)
            }.font(.callout)

            HStack {
                if m.installing { ProgressView().scaleEffect(0.6).frame(width: 16, height: 16) }
                Text(m.status).font(.callout).foregroundStyle(m.status.hasPrefix("✅") ? .green : (m.status.hasPrefix("Failed") ? .red : .primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Quit iSideload") { NSApplication.shared.terminate(nil) }.controlSize(.small).buttonStyle(.borderless)
            }
        }
        .padding(20)
        .frame(width: 440)
        .focusEffectDisabled()   // no stray blue keyboard-focus ring when the popover opens
        .onAppear { m.loadAccountInfo() }
        .confirmationDialog("Which Apple account?", isPresented: $m.showAccountPicker, titleVisibility: .visible) {
            ForEach(m.accounts) { acc in Button(acc.displayName) { m.chooseAccount(acc.appleID) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Which device?", isPresented: $m.showDevicePicker, titleVisibility: .visible) {
            ForEach(m.deviceOptions) { d in Button(d.name) { m.chooseDevice(d.udid) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Handles double-clicked `.ipa` files (via the CFBundleDocumentTypes association) by
/// routing them into the same USB-vs-QR chooser as the in-app "Install from .ipa…" button.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.pathExtension.lowercased() == "ipa" {
            Task { @MainActor in AppModel.shared.openIPA(u.path) }
        }
    }
}

@main
struct InstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    init() {
        CrashLog.bootstrap()                 // crash-safe /tmp/isideload.log, FIRST
        dlog("App.init: start")
        installDiagnosticsLog()
        dlog("App.init: diagnostics installed")
        RefreshDaemon.shared.start()
        dlog("App.init: refresh daemon started")
        // Listen for on-device beacons and push updates over Wi-Fi.
        BeaconListener.shared.start(log: { print("[iSideload beacon] \($0)") })
        dlog("App.init: beacon listener started")
        dlog("App.init: populating teams…")
        Sideloader.populateTeamsInBackground()   // so the team picker is ready + refresh honors the choice
        // Launch at login is ON by default — register once on first run; the Settings
        // toggle can turn it off afterwards (we don't re-enable once configured).
        if !UserDefaults.standard.bool(forKey: "isideload.loginItemConfigured") {
            dlog("App.init: registering login item…")
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "isideload.loginItemConfigured")
        }
        dlog("App.init: done")
    }
    var body: some Scene {
        MenuBarExtra("iSideload", systemImage: "shippingbox") {
            RootPanel()
        }
        .menuBarExtraStyle(.window)
    }
}

// Measures the intrinsic height of the content and sizes the window to fit it, so
// the panel grows/shrinks as sections expand or collapse. A ScrollView only kicks
// in (showing its bar) when the content would be taller than the screen.
// Like the built-in disclosure group, but the chevron sits on the FIRST line of a
// multi-line label (baseline-aligned to it) instead of centered over both lines.
// Content is indented to match the native layout so surrounding alignment is unchanged.
/// Per-account picker of which developer team (free vs paid) to sign with.
struct TeamMenu: View {
    let acc: AccountRecord
    let choose: (String) -> Void
    var body: some View {
        Menu {
            ForEach(acc.teams) { t in
                Button { choose(t.id) } label: {
                    Label(t.label, systemImage: t.id == acc.teamID ? "checkmark" : "")
                }
            }
        } label: {
            let chosen = acc.teamChosen
            HStack(spacing: 3) {
                Image(systemName: chosen ? "person.2" : "exclamationmark.triangle.fill")
                Text(chosen ? "Team: \(acc.teamName)" : "Choose a team")
            }
            .font(.caption2)
            .foregroundStyle(chosen ? Color.secondary : Color.orange)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct FirstLineDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        FirstLineDisclosureView(configuration: configuration)
    }
}

private struct FirstLineDisclosureView: View {
    let configuration: DisclosureGroupStyleConfiguration
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { configuration.isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                configuration.label
            }
            if configuration.isExpanded {
                configuration.content.padding(.leading, 16)
            }
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct RootPanel: View {
    // Start with a sensible height so the window is never 0-tall before the first
    // measurement lands (a 0 frame makes the popover open empty/invisible).
    @State private var contentHeight: CGFloat = 560
    private var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 48 }
    var body: some View {
        ScrollView {
            ContentView()
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                })
        }
        .frame(width: 470, height: min(max(contentHeight, 120), maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { h in
            if h > 1 { contentHeight = h }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)   // pure-white page, readable in dark mode too
        .focusEffectDisabled()                // kill the stray blue focus ring at the window level too
    }
}
