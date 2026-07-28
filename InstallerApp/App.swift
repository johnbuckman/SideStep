// SideStep — lean-AltServer macOS app.
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
    private let q = DispatchQueue(label: "com.decent.sidestep.refresh")
    private var seen = Set<String>()
    private var started = false
    private var tickCount = 0

    func start() {
        guard !started else { return }
        started = true
        q.async { [weak self] in
            CrashLog.log("RefreshDaemon: loop started")
            while true {
                self?.tick()
                Thread.sleep(forTimeInterval: 25)
            }
        }
    }
    private func tick() {
        CrashLog.log("RefreshDaemon: tick \(tickCount + 1) — enumerating devices")
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
            Task { try? await Sideloader.refreshAll(log: { print("[SideStep refresh] \($0)") }) }
        }

        // Daily GitHub-release sweep (separate from the 7-day signing refresh): pulls
        // the newest .ipa for every GitHub-tracked app whose repo has a newer tag.
        let ghKey = "sidestep.lastGithubCheck"
        if now - UserDefaults.standard.double(forKey: ghKey) > 24 * 3600 {
            UserDefaults.standard.set(now, forKey: ghKey)
            Task { await Sideloader.checkGitHubUpdates(log: { print("[SideStep github] \($0)") }) }
        }
    }
}

let SideStepLogPath = (("~/Library/Logs/SideStep.log") as NSString).expandingTildeInPath
// Held for the process lifetime so the diagnostics pipe's read end never closes.
private var diagPipe: Pipe?
private var diagLogFH: FileHandle?

func installDiagnosticsLog() {
    setvbuf(stdout, nil, _IONBF, 0); setvbuf(stderr, nil, _IONBF, 0)
    // Tee stdout+stderr → the on-screen debug log AND the file, so nothing is silent.
    let fm = FileManager.default
    if !fm.fileExists(atPath: SideStepLogPath) {
        try? fm.createDirectory(atPath: (SideStepLogPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: SideStepLogPath, contents: nil)
    }
    guard let logFH = FileHandle(forWritingAtPath: SideStepLogPath) else {
        AltSignLogging.setLogging(true); return
    }
    logFH.seekToEndOfFile()
    let pipe = Pipe()
    diagPipe = pipe        // RETAIN: a local Pipe would dealloc on return, closing the
    diagLogFH = logFH      // read end → writes to the redirected STDOUT raise SIGPIPE
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
    print("\n=== SideStep \(v) launched \(Date()) ===")
    dlog("macOS \(ProcessInfo.processInfo.operatingSystemVersionString); bundle \(Bundle.main.bundleURL.path)")
}

struct DeviceOption: Identifiable {
    let udid: String; let name: String
    let conn: String                     // "usb" | "wifi"
    var devMode: Sideloader.DevMode = .unknown
    var id: String { udid }
    /// e.g. "UK green cover — Wi-Fi" or "Officepad — USB · Developer Mode off"
    var label: String {
        var s = "\(name) — \(conn == "wifi" ? "Wi-Fi" : "USB")"
        switch devMode {
        case .disabled:    s += " · Developer Mode OFF"
        case .unsupported: s += " · no Developer Mode needed"
        case .enabled, .unknown: break
        }
        return s
    }
}
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
    @Published var installAppName = ""       // titles the consolidated install/device dialog
    @Published var installOTACapable = false  // show the "over the air" QR option in that dialog
    private var pendingKind: InstallKind?
    private var pendingInfo: IPAInfo?         // for the QR/over-the-air path
    private var pendingIPAPath: String?
    private var pendingGithub: (repo: String, tag: String)?   // set only for a GitHub install
    private var chosenAppleID: String?

    // GitHub + AltStore dialogs
    @Published var showGitHubInstall = false
    @Published var githubRepoInput = ""
    @Published var showAltStorePrompt = false
    @Published var showGitHubSearch = false
    @Published var githubQuery = ""
    @Published var githubResults: [GitHub.RepoHit] = []
    @Published var githubSearching = false
    @Published var githubSearchNote = "No results yet."

    // AltStore catalog search
    @Published var altStoreQuery = ""
    @Published var altStoreAllApps: [SourceApp] = []
    @Published var altStoreResults: [SourceApp] = []
    @Published var altStoreLoading = false
    @Published var altStoreNote = "Loading app catalog…"
    @Published var altStoreSources: [AltStoreCatalog.Source] = []

    // MARK: accounts

    func login() {
        guard !appleID.isEmpty, !password.isEmpty else { loginStatus = "Enter Apple ID and password."; return }
        loginStage = .working; loginStatus = "Checking your network…"
        let id = appleID, pw = password
        // Refuse the login if another SideStep on the LAN already holds this Apple ID —
        // two Macs on one account race on pushes and burn Apple's limits twice as fast.
        Task { @MainActor in
            if let owner = await LANLock.ownerOnNetwork(appleID: id) {
                self.loginStatus = "“\(id)” is already signed in to SideStep on “\(owner)” on this network. Use one Apple ID per Mac — quit SideStep there first, or sign in with a different account here."
                self.loginStage = .idle
                return
            }
            self.proceedLogin(id: id, pw: pw)
        }
    }

    private func proceedLogin(id: String, pw: String) {
        ALTAppleAPI.preferSMSTwoFactorCode = textMeCode
        loginStage = .working; loginStatus = "Signing in…"
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
        pendingGithub = nil   // a hand-picked .ipa is not from GitHub
        // The "navigate away and come back to select the .ipa" greying bug is caused
        // by the MIXED file+directory mode: with canChooseDirectories=true, macOS
        // renders plain files disabled until the folder is re-enumerated. A .app is a
        // file *package*, which NSOpenPanel already treats as a selectable file, so we
        // do NOT need directory-choosing to pick .app bundles — and folder navigation
        // still works regardless. No content-type filter / delegate either.
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false  // keep .app selectable as one file
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Install"
        dlog("pickIPA: opening file panel")
        // THE greying bug: SideStep is a menu-bar (.accessory / LSUIElement) app, and
        // an accessory app can't make a modal open-panel the KEY window — so its file
        // list renders disabled until you navigate (the "go away and come back" fix is
        // really just forcing a re-render once focus settles). Become a regular,
        // focusable app for the duration of the panel, then restore accessory mode.
        let prevPolicy = NSApp.activationPolicy()
        if prevPolicy != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        let resp = panel.runModal()
        if prevPolicy != .regular { NSApp.setActivationPolicy(prevPolicy) }
        guard resp == .OK, let url = panel.url else { dlog("pickIPA: cancelled"); return }
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
        // Title + OTA option for the consolidated install/device dialog.
        switch kind {
        case .ipa:            installAppName = pendingInfo?.appName ?? "this app"; installOTACapable = pendingInfo?.otaCapable ?? false
        case .source(let a):  installAppName = a.name; installOTACapable = false; pendingInfo = nil; pendingIPAPath = nil
        }
        pendingKind = kind; chosenAppleID = nil
        if accounts.count == 1 {
            guard okToInstall(accounts[0]) else { dlog("startInstall: blocked — team not chosen for \(accounts[0].appleID)"); return }
            chosenAppleID = accounts[0].appleID; resolveDevice()
        } else { dlog("startInstall: multiple accounts — showing picker"); presentAccountPicker() }
    }
    // NSAlert, not a SwiftUI popover dialog: the menu-bar popover closes the moment
    // focus leaves it, which was tearing down every in-panel picker/sheet/textfield.
    func presentAccountPicker() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "Which Apple account?"
        for acc in accounts { a.addButton(withTitle: acc.displayName) }
        a.addButton(withTitle: "Cancel")
        let idx = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if idx >= 0 && idx < accounts.count { chooseAccount(accounts[idx].appleID) }
    }
    func chooseAccount(_ id: String) {
        guard let acc = accounts.first(where: { $0.appleID == id }), okToInstall(acc) else { return }
        chosenAppleID = id; resolveDevice()
    }
    /// Block an install on a multi-team account until the user has chosen which team to sign with.
    private func okToInstall(_ acc: AccountRecord) -> Bool {
        if acc.needsTeamChoice { status = "Pick a team for \(acc.appleID) first (free = 7 days, paid = 1 year)."; return false }
        return true
    }
    private func resolveDevice() {
        status = "Looking for connected devices…"
        dlog("resolveDevice: enumerating connected devices…")
        Task.detached {
            // Enumerate everything (USB + Wi-Fi), then annotate each with its
            // Developer-Mode state (USB-only query; Wi-Fi devices read .unknown).
            let devs = Sideloader.connectedDevices().map { d -> DeviceOption in
                let dm = d.conn == "usb" ? Sideloader.developerMode(d.udid) : .unknown
                return DeviceOption(udid: d.udid, name: d.name, conn: d.conn, devMode: dm)
            }
            dlog("resolveDevice: found \(devs.count) device(s): \(devs.map { "\($0.name)[\($0.conn),dev=\($0.devMode)]=\($0.udid)" }.joined(separator: ", "))")
            await MainActor.run {
                if devs.isEmpty && !self.installOTACapable {
                    self.status = "No iOS device found. Connect one over USB (and tap Trust), or make sure a Wi-Fi-paired device is unlocked, then try again."
                    return
                }
                // ALWAYS let the user choose explicitly — even for a single device — so
                // an install never silently lands on the wrong one.
                self.deviceOptions = devs
                self.presentInstallDialog(devs)
            }
        }
    }
    /// The consolidated "install to which device?" chooser, as an NSAlert so it works
    /// even after the menu-bar popover has closed.
    func presentInstallDialog(_ devs: [DeviceOption]) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = installAppName.isEmpty ? "Install this app?" : "Do you want to install “\(installAppName)”?"
        a.informativeText = devs.isEmpty ? "No device is connected." : "Choose the device to install to."
        for d in devs { a.addButton(withTitle: d.label) }
        if installOTACapable { a.addButton(withTitle: "Show QR code (over the air)") }
        a.addButton(withTitle: "Cancel")
        let idx = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if idx >= 0 && idx < devs.count { chooseDevice(devs[idx].udid) }
        else if installOTACapable && idx == devs.count { startPendingOTA() }
    }

    /// Install-from-GitHub prompt (NSAlert with a focused text field — popover-safe).
    func promptGitHubInstall() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Install from GitHub"
        a.informativeText = "Enter a GitHub repo — owner/name, or paste a full URL like https://github.com/owner/name/releases. SideStep installs the newest .ipa from its Releases and keeps it on the latest release."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        tf.placeholderString = "owner/name  or  https://github.com/owner/name"
        a.accessoryView = tf
        a.addButton(withTitle: "Install"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf   // cursor starts in the field
        if a.runModal() == .alertFirstButtonReturn { installFromGitHub(tf.stringValue) }
    }

    /// AltStore-repo URL prompt (NSAlert with a focused text field).
    func promptAltStore() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Install from AltStore repo"
        a.informativeText = "Enter the URL of an AltStore-format source (a JSON app catalog)."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        tf.placeholderString = "https://…/apps.json"; tf.stringValue = sourceURL
        a.accessoryView = tf
        a.addButton(withTitle: "Load"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf
        if a.runModal() == .alertFirstButtonReturn { sourceURL = tf.stringValue; loadSource() }
    }

    /// Search-GitHub as a standalone window (a sheet inside the popover gets destroyed
    /// when the popover closes).
    private var githubWindow: NSWindow?
    func showGitHubSearchWindow() {
        if let w = githubWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let host = NSHostingView(rootView: GitHubSearchView(m: self))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Search GitHub for iOS apps"
        w.contentView = host; w.center(); w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        githubWindow = w
    }
    func closeGitHubSearch() { githubWindow?.close(); githubWindow = nil }

    func chooseDevice(_ udid: String) {
        // If Developer Mode is off on the chosen (USB) device, guide instead of failing.
        if let d = deviceOptions.first(where: { $0.udid == udid }), d.devMode == .disabled {
            status = "Turning on Developer Mode on “\(d.name)”…"
            dlog("chooseDevice: \(udid) Developer Mode OFF — attempting auto-enable")
            Task.detached { [weak self] in
                let r = Sideloader.tryEnableDeveloperMode(udid)   // also reveals the row
                dlog("chooseDevice: tryEnableDeveloperMode → \(r)")
                await MainActor.run {
                    guard let self else { return }
                    switch r {
                    case .enabled, .rebooting:
                        // No passcode → iOS is enabling it and rebooting on its own.
                        self.status = "Developer Mode is turning on — “\(d.name)” will restart."
                        self.showDevModeHelp(deviceName: d.name, mode: .rebooting)
                    case .needsManual, .unknown:
                        // Passcode set (the common case) → user must flip it themselves.
                        self.status = "“\(d.name)” needs Developer Mode turned on."
                        self.showDevModeHelp(deviceName: d.name, mode: .manual)
                    }
                }
            }
            return
        }
        execute(udid: udid)
    }

    private func execute(udid: String) {
        dlog("execute: udid=\(udid) appleID=\(chosenAppleID ?? "nil") kind=\(pendingKind.map { "\($0)" } ?? "nil")")
        guard let kind = pendingKind, let aid = chosenAppleID,
              let (account, session) = AccountStore.session(for: aid) else {
            status = "Couldn't load that account."
            dlog("execute: ABORT — pendingKind/chosenAppleID/session missing (session for \(chosenAppleID ?? "nil") = \(chosenAppleID.flatMap { AccountStore.session(for: $0) } == nil ? "nil" : "ok"))")
            return
        }
        installing = true; status = "Installing…"
        let gh = pendingGithub; pendingGithub = nil   // remember the GitHub source for this install only
        dlog("execute: starting install task for \(account.appleID)\(gh.map { " (github \($0.repo) \($0.tag))" } ?? "")")
        Task.detached { [weak self] in
            guard let self else { return }
            let log: @Sendable (String) -> Void = { msg in print("[SideStep] \(msg)"); Task { @MainActor in self.status = String(msg.split(separator: "\n").first.map(String.init)?.prefix(160) ?? "") } }
            do {
                let result: String
                switch kind {
                case .ipa(let path): result = try await Sideloader.installFromIPA(account: account, session: session, filePath: path, iPadUDID: udid, github: gh, log: log)
                case .source(let app): result = try await Sideloader.installSourceApp(account: account, session: session, app: app, iPadUDID: udid, log: log)
                }
                dlog("execute: install SUCCEEDED — \(result)")
                await MainActor.run { self.status = result; self.maybeShowTrustHint(appleID: account.appleID) }
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
    private var devModeWindow: NSWindow?

    /// The first app installed from a given Apple ID needs a one-time "trust the
    /// developer" tap; once trusted, every later app from that same account is trusted
    /// automatically. iOS exposes no way to read the trust state, so we approximate:
    /// show the hint only on the FIRST install for this Apple ID, then stay quiet —
    /// if they've installed anything else with this ID, trust is already sorted.
    func maybeShowTrustHint(appleID: String) {
        let key = "sidestep.trusted.\(appleID)"
        if UserDefaults.standard.bool(forKey: key) { return }
        UserDefaults.standard.set(true, forKey: key)
        let a = NSAlert()
        a.messageText = "One-time step: trust this developer"
        a.informativeText = "The first time you install from “\(appleID)”, iOS asks you to trust it before the app will open.\n\nOn the device: Settings ▸ General ▸ VPN & Device Management ▸ tap “\(appleID)” ▸ Trust.\n\nApps you install from this account later won't ask again."
        a.addButton(withTitle: "Got it")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Friendly, roomy popup explaining how to finish enabling Developer Mode.
    func showDevModeHelp(deviceName: String, mode: DevModeHelpView.Mode) {
        if let w = devModeWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let host = NSHostingView(rootView: DevModeHelpView(deviceName: deviceName, mode: mode) { [weak self] in
            self?.devModeWindow?.close(); self?.devModeWindow = nil
        })
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Developer Mode required"
        win.contentView = host
        win.setContentSize(host.fittingSize)   // size to the content — never cramped
        win.center(); win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        devModeWindow = win
    }

    /// Entry point for a picked or double-clicked `.ipa`: inspect it, then go straight
    /// to the consolidated "Do you want to install X?" dialog that lists the devices to
    /// install to. No separate confirm step, and no over-USB/Wi-Fi wording — the chosen
    /// device decides the transport (a Wi-Fi device that's already in Developer Mode +
    /// trusted installs wirelessly). Over-the-air-capable IPAs also get a QR option.
    func openIPA(_ path: String) {
        dlog("openIPA: inspecting \(path)")
        let info = IPAInspector.inspect(path)
        dlog("openIPA: appName=\(info.appName) bundleID=\(info.bundleID) signer=\(info.signer) otaCapable=\(info.otaCapable)")
        pendingInfo = info
        pendingIPAPath = path
        startInstall(.ipa(path))
    }

    /// From the consolidated dialog's "Show QR code (over the air)" option.
    func startPendingOTA() {
        showDevicePicker = false
        if let p = pendingIPAPath, let i = pendingInfo { startOTA(path: p, info: i) }
    }

    // MARK: GitHub

    /// Install the newest .ipa from a GitHub repo (owner/name or a github.com URL),
    /// remembering the repo so the daily check + every refresh keep it current.
    func installFromGitHub(_ input: String) {
        guard let repo = GitHub.normalizeRepo(input) else { status = "Enter a GitHub repo like owner/name."; return }
        status = "Looking up \(repo) on GitHub…"
        Task { @MainActor in
            guard let rel = await GitHub.latestIPA(repo: repo) else { self.status = "No .ipa release found in \(repo)."; return }
            self.status = "Downloading \(rel.ipaName) (\(rel.tag))…"
            do {
                let ipa = try await GitHub.downloadIPA(rel)
                self.pendingGithub = (repo, rel.tag)   // consumed by execute(), stamped onto the tracked app
                self.openIPA(ipa)                      // normal inspect → device picker → install flow
            } catch { self.status = "Download failed: \(error.localizedDescription)" }
        }
    }

    func searchGitHub() {
        let q = githubQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        githubSearching = true; githubResults = []; githubSearchNote = "Searching…"
        Task { @MainActor in
            let hits = await GitHub.searchReposWithIPA(q)
            self.githubResults = hits
            self.githubSearching = false
            if !hits.isEmpty { self.githubSearchNote = ""; return }
            // Empty could mean genuinely nothing, or the hourly core budget is spent
            // (each search probes ~20 repos; unauthenticated GitHub allows only 60/hr).
            let remaining = await GitHub.coreRemaining()
            if let r = remaining, r < 3 {
                self.githubSearchNote = "GitHub's hourly request limit is used up (only 60/hour without a sign-in, and each search checks up to 20 repos). Wait a while and try again — or if you know the app's repo, use “Install from GitHub” by owner/name, which doesn't hit this limit."
            } else {
                self.githubSearchNote = "No repositories with an .ipa release matched “\(q)”. (GitHub can't search release files, so this only matches repo names/descriptions — “Install from GitHub” by owner/name is more reliable.)"
            }
        }
    }

    func installGitHubHit(_ hit: GitHub.RepoHit) { closeGitHubSearch(); installFromGitHub(hit.repo) }

    // MARK: AltStore catalog

    private var altStoreWindow: NSWindow?
    func showAltStoreSearchWindow() {
        if let w = altStoreWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let host = NSHostingView(rootView: AltStoreSearchView(m: self))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Search AltStore apps"; w.contentView = host; w.center(); w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        altStoreWindow = w
        reloadAltStoreSources(); loadAltStore(force: false)
    }
    func closeAltStoreSearch() { altStoreWindow?.close(); altStoreWindow = nil }

    func loadAltStore(force: Bool) {
        altStoreLoading = true; altStoreNote = "Loading app catalog…"
        Task { @MainActor in
            let apps = await AltStoreCatalog.allApps(force: force)
            self.altStoreAllApps = apps; self.altStoreLoading = false; self.filterAltStore()
            if apps.isEmpty { self.altStoreNote = "Couldn't load any sources. Check your connection, or add a source below." }
        }
    }
    func filterAltStore() {
        altStoreResults = AltStoreCatalog.search(altStoreQuery, in: altStoreAllApps)
        if altStoreResults.isEmpty && !altStoreLoading && !altStoreAllApps.isEmpty {
            altStoreNote = "No apps match “\(altStoreQuery)”."
        }
    }
    func installAltStoreApp(_ app: SourceApp) { closeAltStoreSearch(); startInstall(.source(app)) }
    func reloadAltStoreSources() { Task { @MainActor in self.altStoreSources = await AltStoreCatalog.effectiveSources() } }
    func addAltStoreSource(_ url: String) { AltStoreCatalog.addUserSource(url); reloadAltStoreSources(); loadAltStore(force: true) }
    func removeAltStoreSource(_ url: String) { AltStoreCatalog.removeSource(url); reloadAltStoreSources(); loadAltStore(force: true) }

    /// Manually check every GitHub-tracked app for a newer release now.
    func checkGitHubUpdatesNow() {
        status = "Checking GitHub apps for updates…"
        Task.detached { [weak self] in
            await Sideloader.checkGitHubUpdates(log: { print("[SideStep github] \($0)") })
            await MainActor.run { self?.tracked = Tracked.all(); self?.status = "GitHub update check complete." }
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
            let log: @Sendable (String) -> Void = { m in print("[SideStep] \(m)"); Task { @MainActor in self.status = String(m.split(separator: "\n").first.map(String.init)?.prefix(160) ?? "") } }
            do { let r = try await Sideloader.refreshOne(t, log: log); await MainActor.run { self.status = r } }
            catch { await MainActor.run { self.status = "Refresh failed: \(error.localizedDescription)" } }
            await MainActor.run { self.tracked = Tracked.all(); self.installing = false }
        }
    }

    func removeApp(_ t: TrackedApp) {
        installing = true; status = "Removing \(t.name)…"
        Task.detached { [weak self] in
            guard let self else { return }
            let log: @Sendable (String) -> Void = { m in print("[SideStep] \(m)"); Task { @MainActor in self.status = String(m.prefix(160)) } }
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
            let log: @Sendable (String) -> Void = { m in print("[SideStep] \(m)"); Task { @MainActor in self.status = String(m.split(separator: "\n").first.map(String.init)?.prefix(160) ?? "") } }
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

/// Friendly popup explaining how to finish enabling Developer Mode.
/// - `.rebooting`: the device had no passcode, so SideStep already turned Developer
///   Mode on and the device is restarting — the user only confirms afterwards.
/// - `.manual`: the device has a passcode, so iOS won't let us enable it remotely (nor
///   open the Settings app) — SideStep has revealed the row and the user flips it.
struct DevModeHelpView: View {
    enum Mode { case rebooting, manual }
    let deviceName: String
    let mode: Mode
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "hammer.circle.fill")
                    .font(.system(size: 38)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode == .rebooting ? "Developer Mode is turning on" : "One step on \(deviceName): Developer Mode")
                        .font(.title2.weight(.semibold))
                    Text(deviceName).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                if mode == .rebooting {
                    Text("SideStep has turned Developer Mode on. **\(deviceName) is restarting now.** When it comes back:")
                        .fixedSize(horizontal: false, vertical: true)
                    step(1, "Unlock \(deviceName).")
                    step(2, "Tap **Turn On** when it asks to confirm Developer Mode.")
                } else {
                    Text("Developer Mode has to be switched on from the device itself. SideStep has added it to Settings for you — iOS doesn't allow an app to open Settings on your behalf, so on \(deviceName):")
                        .fixedSize(horizontal: false, vertical: true)
                    step(1, "Open **Settings ▸ Privacy & Security ▸ Developer Mode**.")
                    step(2, "Switch **Developer Mode** on.")
                    step(3, "Tap **Restart** when it asks — the device reboots.")
                    step(4, "After it restarts, tap **Turn On** to confirm.")
                }
                Text("Then try to install your app again.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 2)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))

            if mode == .manual {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Don't see “Developer Mode”? Keep \(deviceName) connected and reopen Settings — connecting it just now is what makes the row appear.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Got it") { onClose() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    @ViewBuilder private func step(_ n: Int, _ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Text("\(n)")
                .font(.footnote.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.orange))
            Text(.init(markdown))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
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
            Text("Then tap **Install** on your device. First time on a device: enable **Settings ▸ Privacy & Security ▸ Developer Mode** (it restarts once). Keep SideStep open until it finishes.")
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
    @State private var settingsExpanded = false

    /// A small caption: how the app was found + whether it auto-updates.
    @ViewBuilder private func appOriginLine(_ t: TrackedApp) -> some View {
        HStack(spacing: 5) {
            Image(systemName: t.autoUpdates ? "arrow.triangle.2.circlepath" : "doc")
                .font(.system(size: 9))
            Text(t.autoUpdates ? "Keeps up to date" : "One-time install").fontWeight(.medium)
            if t.githubRepo.isEmpty {   // (GitHub already shows the repo link on the line above)
                if t.origin.hasPrefix("http") { Text("· \(t.origin)").lineLimit(1).truncationMode(.middle) }
                else if !t.origin.isEmpty { Text("· \((t.origin as NSString).lastPathComponent)").lineLimit(1).truncationMode(.middle) }
            }
        }
        .font(.caption2)
        .foregroundStyle(t.autoUpdates ? Color.green : Color.secondary)
    }

    /// The installed app's real icon (cached at install), or the generic symbol.
    @ViewBuilder private func appIcon(bundleID: String) -> some View {
        if !bundleID.isEmpty, let img = NSImage(contentsOfFile: AppIconCache.path(bundleID: bundleID)) {
            Image(nsImage: img).resizable().interpolation(.high)
                .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(systemName: "square.grid.2x2.fill").frame(width: 20).foregroundStyle(.secondary)
        }
    }
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
            Text("SideStep").font(.title2).bold()
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
                                VStack(alignment: .leading, spacing: 1) {
                                  HStack(spacing: 6) {
                                    appIcon(bundleID: grp.devices.first?.installedBundleID ?? "")
                                    Text(grp.name).font(.callout)
                                    if let v = grp.devices.first?.version, !v.isEmpty {
                                        Text("v\(v)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let repo = grp.devices.first?.githubRepo, !repo.isEmpty,
                                       let url = URL(string: "https://github.com/\(repo)") {
                                        Text(":").font(.caption2).foregroundStyle(.secondary)
                                        Link(repo, destination: url).font(.caption2)
                                    }
                                  }
                                  if let t = grp.devices.first { appOriginLine(t) }
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
                    Button("Install from .ipa") { m.pickIPA() }.disabled(m.installing)
                    Button("Install from GitHub") { m.promptGitHubInstall() }.disabled(m.installing)
                    Button("Search GitHub") { m.showGitHubSearchWindow() }.disabled(m.installing)
                }
                HStack {
                    Button("Search AltStore") { m.showAltStoreSearchWindow() }.disabled(m.installing)
                    Button("Install from AltStore repo") { m.promptAltStore() }.disabled(m.installing)
                    Button("Install from .json") { m.pickJSON() }.disabled(m.installing)
                }
                  }
                }.font(.headline)
            }

            Divider()
            DisclosureGroup(isExpanded: $settingsExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Launch SideStep at login (keeps apps auto-refreshed)", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
                    Button("Refresh all apps now") { m.refreshAllNow() }.disabled(m.installing)
                    Button("Check GitHub apps for updates now") { m.checkGitHubUpdatesNow() }.disabled(m.installing)
                    Button("Check for SideStep Update now") { Task { await UpdateChecker.shared.check(userInitiated: true) } }
                    Button("Show Debug Log…") { DebugWindow.show() }
                    Text("SideStep keeps apps signed while it runs in the menu bar — it re-signs automatically when you plug in a device and every couple of hours. No separate background program is needed.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 2)
            } label: {
                // Whole "Settings" word toggles, not just the chevron.
                Text("Settings").contentShape(Rectangle()).onTapGesture { settingsExpanded.toggle() }
            }.font(.callout)

            HStack {
                if m.installing { ProgressView().scaleEffect(0.6).frame(width: 16, height: 16) }
                Text(m.status).font(.callout).foregroundStyle(m.status.hasPrefix("✅") ? .green : (m.status.hasPrefix("Failed") ? .red : .primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Quit SideStep") { NSApplication.shared.terminate(nil) }.controlSize(.small).buttonStyle(.borderless)
            }
        }
        .padding(20)
        .frame(width: 440)
        .focusEffectDisabled()   // no stray blue keyboard-focus ring when the popover opens
        .onAppear { m.loadAccountInfo() }
        // Account/device pickers + GitHub/AltStore prompts + GitHub search are all
        // presented as NSAlerts / a standalone NSWindow (see AppModel) because a
        // SwiftUI dialog/sheet/textfield inside the MenuBarExtra popover is destroyed
        // the moment the popover loses focus.
    }
}

/// Search GitHub for repos that ship an installable `.ipa`, and install one.
/// Search across curated AltStore source catalogs (no GitHub rate limits) and install.
struct AltStoreSearchView: View {
    @ObservedObject var m: AppModel
    @State private var newSource = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install apps from AltStore sources").font(.headline)
            Text("Searches curated AltStore catalogs (open-source apps, emulators, official apps). Uses plain source JSON — no GitHub rate limits.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("search apps…", text: $m.altStoreQuery).textFieldStyle(.roundedBorder)
                    .onChange(of: m.altStoreQuery) { _ in m.filterAltStore() }
                if m.altStoreLoading { ProgressView().scaleEffect(0.6).frame(width: 14, height: 14) }
                Button("Reload") { m.loadAltStore(force: true) }.disabled(m.altStoreLoading)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if m.altStoreResults.isEmpty {
                        Text(m.altStoreNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(m.altStoreResults) { app in
                        HStack(alignment: .top, spacing: 8) {
                            AsyncImage(url: app.iconURL.flatMap { URL(string: $0) }) { img in img.resizable() }
                                placeholder: { RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.15)) }
                                .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(app.name).font(.callout.weight(.medium))
                                    if let v = app.version, !v.isEmpty { Text("v\(v)").font(.caption2).foregroundStyle(.secondary) }
                                }
                                if let d = app.localizedDescription, !d.isEmpty {
                                    Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }
                                Text(app.sourceName).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Install") { m.installAltStoreApp(app) }.disabled(m.installing)
                        }
                        Divider()
                    }
                }
            }
            DisclosureGroup("Sources (\(m.altStoreSources.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(m.altStoreSources) { s in
                        HStack(spacing: 6) {
                            Text(s.url).font(.caption2).lineLimit(1).truncationMode(.middle)
                            if s.isDefault { Text("default").font(.caption2).foregroundStyle(.tertiary) }
                            Spacer()
                            Button { m.removeAltStoreSource(s.url) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("add a source URL…", text: $newSource).textFieldStyle(.roundedBorder)
                        Button("Add") { m.addAltStoreSource(newSource); newSource = "" }.disabled(newSource.isEmpty)
                    }
                    Text("Add legitimate AltStore-format source URLs. The default list lives in SideStep’s repo (sources.json) — send a PR to add to it.")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
            }.font(.callout)
            HStack { Spacer(); Button("Done") { m.closeAltStoreSearch() } }
        }
        .padding(16).frame(width: 520, height: 580)
    }
}

struct GitHubSearchView: View {
    @ObservedObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search GitHub for iOS apps").font(.headline)
            Text("Matches repository names/descriptions, then keeps the ones whose releases include an .ipa. GitHub can't search release files directly, so this is best-effort — if you know the repo, “Install from GitHub” by owner/name is more reliable.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("app name or keywords", text: $m.githubQuery)
                    .textFieldStyle(.roundedBorder).onSubmit { m.searchGitHub() }
                Button("Search") { m.searchGitHub() }.keyboardShortcut(.defaultAction).disabled(m.githubSearching)
                if m.githubSearching { ProgressView().scaleEffect(0.6).frame(width: 14, height: 14) }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if m.githubResults.isEmpty {
                        Text(m.githubSearchNote).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(m.githubResults) { hit in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.repo).font(.callout.weight(.medium))
                                if !hit.description.isEmpty {
                                    Text(hit.description).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }
                                if let ipa = hit.ipa { Text("latest: \(ipa.tag) · \(ipa.ipaName)").font(.caption2).foregroundStyle(.tertiary) }
                            }
                            Spacer()
                            Button("Install") { m.installGitHubHit(hit) }.disabled(m.installing)
                        }
                        Divider()
                    }
                }
            }
            HStack { Spacer(); Button("Done") { m.closeGitHubSearch() } }
        }
        .padding(16).frame(width: 460, height: 420)
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

    // Lifecycle instrumentation — the app on some Macs quit cleanly right after
    // init() with no crash report. These log exactly how far past init it gets
    // and whether it terminates via the normal AppKit path (delegate fires) or is
    // killed (no willTerminate line). Crash-safe /tmp log, so it survives.
    func applicationDidFinishLaunching(_ n: Notification) {
        CrashLog.log("app: applicationDidFinishLaunching (activationPolicy=\(NSApp.activationPolicy().rawValue), windows=\(NSApp.windows.count))")
        // Belt-and-braces: a menu-bar-only app must be .accessory, not .prohibited.
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationWillTerminate(_ n: Notification) {
        CrashLog.log("app: applicationWillTerminate — clean shutdown via AppKit")
    }
    // A MenuBarExtra app has no persistent window; never quit just because the
    // menu panel (or a transient window) closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        CrashLog.log("app: applicationShouldTerminateAfterLastWindowClosed? -> NO")
        return false
    }
}

@main
struct InstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    init() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        CrashLog.bootstrap(version: v)        // crash-safe /tmp/sidestep.log, FIRST
        dlog("App.init: start")
        installDiagnosticsLog()
        dlog("App.init: diagnostics installed")
        // The refresh daemon + beacon listener spawn background work (subprocess,
        // UDP socket, Bonjour). Defer them until after the app is up so init can
        // finish and the UI appears — and so any failure is isolated + logged.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            dlog("post-launch: starting RefreshDaemon…")
            RefreshDaemon.shared.start()
            dlog("post-launch: RefreshDaemon started")
            dlog("post-launch: starting BeaconListener…")
            BeaconListener.shared.start(log: { print("[SideStep beacon] \($0)") })
            dlog("post-launch: BeaconListener started")
            UpdateChecker.shared.checkIfDue()   // daily GitHub-Releases self-update check
        }
        dlog("App.init: populating teams…")
        Sideloader.populateTeamsInBackground()   // so the team picker is ready + refresh honors the choice
        // Launch at login is ON by default — register once on first run; the Settings
        // toggle can turn it off afterwards (we don't re-enable once configured).
        if !UserDefaults.standard.bool(forKey: "sidestep.loginItemConfigured") {
            dlog("App.init: registering login item…")
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "sidestep.loginItemConfigured")
        }
        dlog("App.init: done")
    }
    var body: some Scene {
        MenuBarExtra("SideStep", systemImage: "shippingbox") {
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
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    var body: some View {
        ScrollView {
            ContentView()
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                })
        }
        .overlay(alignment: .topTrailing) {
            Text(appVersion.isEmpty ? "" : "v\(appVersion)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.top, 8).padding(.trailing, 12)
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
