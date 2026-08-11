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

/// The beacon listener + install server open LAN sockets (UDP broadcast, a TCP
/// listener, and Bonjour advertising), which is what makes macOS 15+ show the
/// one-time "SideStep would like to find devices on your local network" prompt.
/// macOS gives no API to query that permission's state, so we can't literally
/// "check before asking" — the closest equivalent is to only ask when the feature
/// is actually reachable: start these servers only once SideStep has installed at
/// least one app that could beacon for a Wi-Fi update. A fresh SideStep with no
/// sideloaded apps never opens these sockets, so it never provokes the prompt.
/// Both `.start()` calls self-guard against double-start, so this is safe to call
/// repeatedly (at launch, and again right after the first install).
enum LANServices {
    static func startIfNeeded() {
        guard !Tracked.all().isEmpty else {
            dlog("LANServices: skipped — no tracked apps yet (avoids the Local Network prompt)")
            return
        }
        dlog("LANServices: starting beacon listener + install server")
        BeaconListener.shared.start(log: { print("[SideStep beacon] \($0)") })
        InstallServer.shared.start(log: { print("[SideStep installsrv] \($0)") })
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
    // Install progress/result window — so that once an install starts, the user sees a
    // live progress window that ends with the outcome + an OK button, and never has to
    // reopen SideStep to find out what happened.
    @Published var ipTitle = ""            // "Installing X on <device>"
    @Published var ipStatus = ""           // live status line
    @Published var ipDone = false          // terminal state reached
    @Published var ipOK = false            // terminal outcome (success/failure)
    @Published var ipResult = ""           // final message shown alongside the OK button
    @Published var ipProgress: Double?     // fraction 0…1 (nil = indeterminate/spinner)
    @Published var ipDetail = ""           // "42% · 3.1 MB of 7.4 MB · ~8s left"
    private var dlStart: Date?             // when the current download began (for ETA)
    private var phaseStart: Date?          // when the current install sub-phase began (for ETA)
    private var phaseKey = ""              // current install sub-phase ("Uploading"/"Installing")
    @Published var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @Published var sourceURL = ""
    @Published var sourceApps: [SourceApp] = []

    // pickers
    @Published var showAccountPicker = false
    @Published var showDevicePicker = false
    @Published var deviceOptions: [DeviceOption] = []
    @Published var installAppName = ""       // titles the consolidated install/device dialog
    private var pendingKind: InstallKind?
    private var pendingGithub: (repo: String, tag: String)?   // set only for a GitHub install
    private var chosenAppleID: String?
    // When an install is requested with no Apple ID signed in (only reachable from a
    // sidestep:// deep-link), we pop up the Add-Apple-ID sign-in and resume this install
    // once the user has signed in.
    private var resumeInstallAfterLogin = false

    // GitHub + AltStore dialogs
    @Published var showGitHubInstall = false
    @Published var githubRepoInput = ""
    @Published var showAltStorePrompt = false
    @Published var showGitHubSearch = false
    @Published var githubQuery = ""
    @Published var githubResults: [GitHub.RepoHit] = []
    @Published var githubSearching = false
    @Published var githubSearchNote = "No results yet."
    // Set when a search failed because GitHub's unauthenticated rate limit is spent
    // AND no token is saved — the view then offers to add a personal-access token.
    @Published var githubOfferToken = false
    @Published var githubHasToken = GitHub.hasToken

    // sidestep:// deep-link "land here, then tap Install" confirmation. A URL is
    // untrusted input (it can arrive from any webpage), so the deep-link only ever
    // *lands* on this confirm window naming the repo — the actual download/install
    // never fires until the user clicks Install.
    @Published var confirmRepo = ""            // "owner/name"
    @Published var confirmReleaseLine = ""     // "vX.Y — App.ipa" once the release is looked up
    @Published var confirmChecking = false
    @Published var confirmTokenWarning: String? = nil   // GitHub's reason a saved token was rejected

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
                            // Resume a deep-link install that was waiting on the user's first
                            // Apple ID (the Add-Apple-ID popup path): close the popup and pick
                            // up the install right where it left off.
                            if self.resumeInstallAfterLogin, let k = self.pendingKind {
                                self.resumeInstallAfterLogin = false
                                self.closeAddAccount()
                                self.startInstall(k)
                            }
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
        // No Apple ID yet. This is only reachable from a sidestep:// deep-link (the in-panel
        // Install actions stay hidden until an account exists), so the menu-bar popover — which
        // hosts the sign-in form — isn't open; just flipping `addingAccount` would prompt in a
        // panel nobody can see, and the install would silently stall. Instead, at this same
        // account-decision point (cf. the >1-account picker just below), pop up the Add-Apple-ID
        // sign-in as its own window and resume this install once the user has signed in.
        guard !accounts.isEmpty else {
            pendingKind = kind; resumeInstallAfterLogin = true
            dlog("startInstall: no accounts — prompting Add Apple ID popup")
            presentAddAccount()
            return
        }
        // Title for the consolidated install/device dialog.
        switch kind {
        case .ipa(let path):  installAppName = Sideloader.quickAppName(path)   // "Magnatune", not the raw file name
        case .source(let a):  installAppName = a.name
        }
        pendingKind = kind; chosenAppleID = nil
        if accounts.count == 1 {
            guard okToInstall(accounts[0]) else { dlog("startInstall: blocked — team not chosen for \(accounts[0].appleID)"); return }
            chosenAppleID = accounts[0].appleID; resolveDevice()
        } else { dlog("startInstall: multiple accounts — showing picker"); presentAccountPicker() }
    }
    // NSAlert, not a SwiftUI popover dialog: the menu-bar popover closes the moment
    // focus leaves it, which was tearing down every in-panel picker/sheet/textfield.
    /// (bundleID, name) of the app about to be installed, for matching prior installs.
    private func pendingAppIdentity() -> (bundleID: String?, name: String?) {
        switch pendingKind {
        case .source(let app): return (app.bundleIdentifier, app.name)
        case .ipa:             return (nil, installAppName)
        case .none:            return (nil, nil)
        }
    }
    /// Apple IDs that have already installed this app (matched by original bundle id,
    /// else by name). Reusing one avoids spending another of that ID's 3 app slots.
    private func priorAppleIDs(bundleID: String?, name: String?) -> Set<String> {
        var ids = Set<String>()
        for t in Tracked.all() {
            if let b = bundleID, !b.isEmpty, t.origBundleID == b { ids.insert(t.appleID) }
            else if let n = name, !n.isEmpty, t.name.caseInsensitiveCompare(n) == .orderedSame { ids.insert(t.appleID) }
        }
        return ids
    }

    func presentAccountPicker() {
        NSApp.activate(ignoringOtherApps: true)
        let (bid, nm) = pendingAppIdentity()
        let prior = priorAppleIDs(bundleID: bid, name: nm)
        // Put an Apple ID already used for this app first (recommended) and label it,
        // so the user reuses it instead of burning a slot on another ID.
        let ordered = accounts.sorted { (prior.contains($0.appleID) ? 0 : 1) < (prior.contains($1.appleID) ? 0 : 1) }
        let a = NSAlert(); a.messageText = "Which Apple account?"
        for acc in ordered {
            a.addButton(withTitle: prior.contains(acc.appleID) ? "\(acc.displayName)  (previously used for this app)" : acc.displayName)
        }
        a.addButton(withTitle: "Cancel")
        let idx = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if idx >= 0 && idx < ordered.count { chooseAccount(ordered[idx].appleID) }
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
                if devs.isEmpty {
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
        a.addButton(withTitle: "Cancel")
        let idx = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if idx >= 0 && idx < devs.count { chooseDevice(devs[idx].udid) }
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

    // MARK: sidestep:// deep links
    /// Route a sidestep:// URL. Supported today:
    ///   sidestep://install?repo=owner/name   → land on the Install confirm window
    ///   sidestep://install?repo=owner         → land on that user's app list
    ///   sidestep://install/owner/name         → path form, same as ?repo=
    /// A URL can come from an untrusted webpage, so we never auto-install — we only
    /// open a window where the user taps Install themselves.
    func handleURLScheme(_ url: URL) {
        dlog("sidestep:// open \(url.absoluteString)")
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        switch (comps.host ?? "").lowercased() {
        case "install":
            var repo = comps.queryItems?.first(where: { $0.name == "repo" })?.value ?? ""
            if repo.isEmpty { repo = comps.path }              // path form: /owner/name
            repo = repo.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
            guard !repo.isEmpty else { promptGitHubInstall(); return }   // no repo → manual prompt
            if let norm = GitHub.normalizeRepo(repo) {
                presentGitHubInstall(repo: norm)               // owner/name → confirm window
            } else if !repo.contains("/") {
                installFromGitHubUser(repo)                     // bare username → their app list
            } else {
                presentGitHubInstall(repo: repo)               // best-effort; confirm window reports "not found"
            }
        default:
            dlog("sidestep:// unknown action \(comps.host ?? "")")
        }
    }

    /// Open (or reuse) the deep-link confirm window for `repo` and look up its newest
    /// release so the window can show what will be installed. Nothing downloads here.
    private var githubConfirmWindow: NSWindow?
    func presentGitHubInstall(repo: String) {
        confirmRepo = repo; confirmReleaseLine = ""; confirmChecking = true; confirmTokenWarning = nil
        if let w = githubConfirmWindow {
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } else {
            // NSHostingController so the window grows to fit the release line + any
            // token-rejected warning that appears after the async lookup.
            let host = NSHostingController(rootView: GitHubConfirmView(m: self))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable]
            w.title = "Install from GitHub"
            w.center(); w.isReleasedWhenClosed = false
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            githubConfirmWindow = w
        }
        Task { @MainActor in
            let rel = await GitHub.latestIPA(repo: repo)
            guard self.confirmRepo == repo else { return }     // a newer request superseded this one
            self.confirmChecking = false
            self.confirmReleaseLine = rel.map { "\($0.tag) — \($0.ipaName)" }
                ?? "No installable .ipa release found in this repo."
            // If a saved token was rejected during the lookup, surface why (SideStep fell
            // back to unauthenticated so this still worked, but at the 60/hr limit).
            self.confirmTokenWarning = GitHub.tokenRejection
        }
    }
    /// User tapped Install in the confirm window → run the normal GitHub install flow.
    func confirmGitHubInstall() {
        let repo = confirmRepo
        closeGitHubConfirm()
        installFromGitHub(repo)
    }
    func closeGitHubConfirm() { githubConfirmWindow?.close(); githubConfirmWindow = nil }

    // MARK: Add-Apple-ID popup (popover-safe window)
    // Shown when an install is requested but no Apple ID is signed in — e.g. a first-time
    // sidestep:// deep-link, where the menu-bar popover (which normally hosts the sign-in
    // form) isn't open. Same fields as the in-panel form, but as its own window; on a
    // successful sign-in the pending install resumes automatically (see proceedLogin).
    private var addAccountWindow: NSWindow?
    func presentAddAccount() {
        addingAccount = true                       // put the shared login state into add mode
        loginStage = .idle; loginStatus = ""
        NSApp.activate(ignoringOtherApps: true)
        if let w = addAccountWindow { w.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: AddAccountView(m: self))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = "Add an Apple ID"
        w.center(); w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        addAccountWindow = w
    }
    func closeAddAccount() { addAccountWindow?.close(); addAccountWindow = nil }
    /// User dismissed the Add-Apple-ID popup without signing in — drop the pending install.
    func cancelAddAccount() { resumeInstallAfterLogin = false; cancelLogin(); closeAddAccount() }

    // MARK: install progress/result window
    private var installProgressWindow: NSWindow?
    /// Open (or reuse) the install-progress window and reset it to a running state.
    /// Feed byte counts from a running download into the progress window: a determinate
    /// fraction when the server sent a Content-Length, plus a human "42% · 3.1 MB of
    /// 7.4 MB · ~8s left" line. Times the download from its first callback to estimate
    /// the ETA (smoothed by the overall average rate, which is stable enough here).
    @MainActor
    func reportDownload(received: Int64, total: Int64) {
        if dlStart == nil { dlStart = Date() }
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard total > 0 else {                       // no Content-Length: keep the spinner, show bytes so far
            ipProgress = nil
            ipDetail = "\(got) downloaded"
            return
        }
        let frac = min(1.0, Double(received) / Double(total))
        ipProgress = frac
        let tot = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        var eta = ""
        let elapsed = Date().timeIntervalSince(dlStart ?? Date())
        if elapsed > 0.5, received > 0, received < total {
            let rate = Double(received) / elapsed     // bytes/sec, averaged over the whole download
            if rate > 0 { eta = " · \(Self.formatETA(Double(total - received) / rate)) left" }
        }
        ipDetail = "\(Int(frac * 100))% · \(got) of \(tot)\(eta)"
    }

    /// Progress for the on-device step: the helper streams a percentage first as it
    /// copies the IPA to the device ("Uploading"), then as installation_proxy installs it
    /// ("Installing"). Each sub-phase gets its own ETA clock, so the estimate restarts
    /// cleanly at the hand-off instead of lurching.
    @MainActor
    func reportInstallProgress(percent: Int, phase: String) {
        let pct = max(0, min(100, percent))
        if phaseKey != phase { phaseKey = phase; phaseStart = Date() }
        ipProgress = Double(pct) / 100
        ipStatus = phase == "Uploading" ? "Copying to device…" : "Installing on device…"
        var eta = ""
        let elapsed = Date().timeIntervalSince(phaseStart ?? Date())
        if elapsed > 0.5, pct > 1, pct < 100 {
            let totalTime = elapsed / (Double(pct) / 100)   // project total from average rate
            eta = " · \(Self.formatETA(totalTime - elapsed)) left"
        }
        ipDetail = "\(pct)%\(eta)"
    }

    /// Drop the determinate bar back to the spinner once a phase hands off to work that
    /// reports no progress (signing, provisioning).
    @MainActor
    func clearDownloadProgress() { ipProgress = nil; ipDetail = ""; dlStart = nil; phaseStart = nil; phaseKey = "" }

    static func formatETA(_ seconds: Double) -> String {
        if seconds < 1 { return "~1s" }
        if seconds < 60 { return "~\(Int(seconds.rounded()))s" }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return s == 0 ? "~\(m)m" : "~\(m)m \(s)s"
    }

    func beginInstallProgress(title: String) {
        ipTitle = title; ipStatus = "Starting…"; ipDone = false; ipOK = false; ipResult = ""
        clearDownloadProgress()
        if let w = installProgressWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        // Drive the window from an NSHostingController so AppKit sizes it to the SwiftUI
        // content and re-fits automatically when the result text grows — the old manual
        // fittingSize on a plain contentView left the window too short and clipped the
        // OK button.
        let host = NSHostingController(rootView: InstallProgressView(m: self))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = "Installing"
        w.center(); w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        installProgressWindow = w
    }
    /// Mark the install finished with an outcome; the window shows it + an OK button.
    func finishInstallProgress(ok: Bool, message: String) {
        ipDone = true; ipOK = ok
        clearDownloadProgress()
        // The result view already shows a green check icon on success, so drop the
        // leading "✅ " from the message (otherwise the user sees two green checks).
        var text = message
        if text.hasPrefix("✅ ") { text.removeFirst(2) }
        // On success, remind the user of the one remaining on-device step.
        if ok {
            text += "\n\nOn your device, open Settings ▸ General ▸ VPN & Device Management and trust the developer to launch the app."
        }
        ipResult = text
        ipStatus = ok ? "Done." : "Failed."
        // The window is an NSHostingController, so it re-fits to the taller result on
        // its own — no manual resize needed.
        NSApp.activate(ignoringOtherApps: true)
        installProgressWindow?.makeKeyAndOrderFront(nil)
    }
    func closeInstallProgress() { installProgressWindow?.close(); installProgressWindow = nil }

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
        // Show the live progress/result window so the outcome is always visible without
        // reopening SideStep. Name the actual target device (never a hardcoded "iPad").
        let deviceName = deviceOptions.first(where: { $0.udid == udid })?.name ?? ""
        beginInstallProgress(title: installAppName.isEmpty
            ? (deviceName.isEmpty ? "Installing…" : "Installing on \(deviceName)")
            : "Installing “\(installAppName)”\(deviceName.isEmpty ? "" : " on \(deviceName)")")
        let gh = pendingGithub; pendingGithub = nil   // remember the GitHub source for this install only
        dlog("execute: starting install task for \(account.appleID)\(gh.map { " (github \($0.repo) \($0.tag))" } ?? "")")
        Task.detached { [weak self] in
            guard let self else { return }
            let log: @Sendable (String) -> Void = { msg in
                print("[SideStep] \(msg)")
                let line = String(msg.split(separator: "\n").first.map(String.init)?.prefix(160) ?? "")
                Task { @MainActor in
                    self.status = line
                    if !line.isEmpty { self.ipStatus = line }
                    // Any non-download status (signing, provisioning, installing) means the
                    // download is done — swap the determinate bar back for the spinner.
                    if !line.contains("Downloading") { self.clearDownloadProgress() }
                }
            }
            // Live byte progress → determinate bar + ETA in the install window.
            let onProgress: @Sendable (Int64, Int64) -> Void = { received, total in
                Task { @MainActor in self.reportDownload(received: received, total: total) }
            }
            // Live on-device progress (copy to device, then install) → same bar + ETA.
            let onInstall: @Sendable (Int, String) -> Void = { percent, phase in
                Task { @MainActor in self.reportInstallProgress(percent: percent, phase: phase) }
            }
            // Shown only when an app to be installed looks like a known PAID App Store
            // app — a legitimate owner can proceed; the default (Cancel) refuses.
            let confirm: @Sendable (String, String) async -> Bool = { app, bid in
                await MainActor.run {
                    let a = NSAlert()
                    a.messageText = "Is this a legitimate copy of \(app)?"
                    a.informativeText = "This looks like \(app) (\(bid)) — a paid App Store app. SideStep won't help distribute pirated apps.\n\nContinue only if you own this app or otherwise have the right to install this build."
                    a.alertStyle = .warning
                    a.addButton(withTitle: "Cancel")            // default
                    a.addButton(withTitle: "I have the rights")
                    NSApp.activate(ignoringOtherApps: true)
                    return a.runModal() == .alertSecondButtonReturn
                }
            }
            do {
                let result: String
                switch kind {
                case .ipa(let path): result = try await Sideloader.installFromIPA(account: account, session: session, filePath: path, iPadUDID: udid, github: gh, confirm: confirm, log: log, onInstall: onInstall)
                case .source(let app): result = try await Sideloader.installSourceApp(account: account, session: session, app: app, iPadUDID: udid, confirm: confirm, log: log, onProgress: onProgress, onInstall: onInstall)
                }
                dlog("execute: install SUCCEEDED — \(result)")
                await MainActor.run { self.status = result; self.finishInstallProgress(ok: true, message: result); self.maybeShowTrustHint(appleID: account.appleID); LANServices.startIfNeeded() }
            } catch {
                dlog("execute: INSTALL FAILED — \(String(reflecting: error))")
                if case SideErr.deviceLimit(let aid, let devName, let bid, let others) = error {
                    // The device-limit retry dialog supersedes the progress window — close it
                    // so the two don't stack; the retry path reopens progress on its next try.
                    await MainActor.run { self.installing = false; self.closeInstallProgress(); self.presentDeviceLimitRetry(appleID: aid, deviceName: devName, bundleID: bid, others: others, udid: udid) }
                    return
                }
                await MainActor.run { self.status = "Failed: \(error.localizedDescription)"; self.finishInstallProgress(ok: false, message: "Failed: \(error.localizedDescription)") }
            }
            await MainActor.run { self.tracked = Tracked.all(); self.installing = false }
        }
    }

    /// Apple refused to register this device (hit the per-Apple-ID device limit).
    /// Explain it and, if other Apple IDs are set up, offer one-tap retry on each.
    @MainActor
    func presentDeviceLimitRetry(appleID: String, deviceName: String, bundleID: String, others: [String], udid: String) {
        let a = NSAlert()
        a.messageText = "Apple won’t register \(deviceName.isEmpty ? "this device" : "“\(deviceName)”")"
        a.alertStyle = .warning
        var info = "The Apple ID \(appleID) has reached Apple’s limit on how many devices it can register, so this device can’t be added — that’s why iOS wouldn’t install the app. Apple doesn’t let a free Apple ID remove old devices, so to install on more devices, use a different Apple ID."
        // Prefer an Apple ID already used for THIS app — reusing it doesn't spend
        // another of that ID's 3 app slots. Show those first, labelled.
        let prior = priorAppleIDs(bundleID: bundleID, name: nil)
        let choices = Array(others.sorted { (prior.contains($0) ? 0 : 1) < (prior.contains($1) ? 0 : 1) }.prefix(3))
        if choices.isEmpty {
            info += "\n\nAdd another Apple ID in SideStep (Add account), then try again."
        } else {
            info += "\n\nInstall with a different Apple ID:"
            for aid in choices { a.addButton(withTitle: prior.contains(aid) ? "Use \(aid)  (previously used for this app)" : "Use \(aid)") }
        }
        a.addButton(withTitle: "Cancel")
        a.informativeText = info
        NSApp.activate(ignoringOtherApps: true)
        let resp = a.runModal()
        let idx = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if idx >= 0 && idx < choices.count {
            chosenAppleID = choices[idx]               // pendingKind is still set — retry the same install
            status = "Retrying on \(choices[idx])…"
            execute(udid: udid)
        } else {
            status = "Install cancelled — \(appleID) can’t register more devices."
        }
    }

    // MARK: IPA routing (double-clicked / picked .ipa)

    static let shared = AppModel()
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

    /// Entry point for a picked or double-clicked `.ipa`: go straight to the
    /// consolidated "Do you want to install X?" dialog listing the devices to install
    /// to. The chosen device decides the transport (USB, or Wi-Fi for a device already
    /// in Developer Mode + trusted).
    func openIPA(_ path: String) {
        dlog("openIPA: \(path)")
        startInstall(.ipa(path))
    }

    // MARK: GitHub

    /// Install the newest .ipa from a GitHub repo (owner/name or a github.com URL),
    /// remembering the repo so the daily check + every refresh keep it current.
    func installFromGitHub(_ input: String) {
        // A bare username (no "owner/name") → list that user's repos that ship an .ipa.
        let core = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://github.com/", with: "")
            .replacingOccurrences(of: "github.com/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !core.isEmpty && !core.contains("/") { installFromGitHubUser(core); return }
        guard let repo = GitHub.normalizeRepo(input) else { status = "Enter a GitHub repo like owner/name, or just a username."; return }
        status = "Looking up \(repo) on GitHub…"
        Task { @MainActor in
            guard let rel = await GitHub.latestIPA(repo: repo) else { self.status = "No .ipa release found in \(repo)."; return }
            self.status = "Downloading \(rel.ipaName) (\(rel.tag))…"
            let name = rel.ipaName
            let onProgress: @Sendable (Int64, Int64) -> Void = { received, total in
                Task { @MainActor in
                    guard total > 0 else { return }
                    let pct = Int(min(1.0, Double(received) / Double(total)) * 100)
                    self.status = "Downloading \(name)… \(pct)%"
                }
            }
            do {
                let ipa = try await GitHub.downloadIPA(rel, onProgress: onProgress)
                self.pendingGithub = (repo, rel.tag)   // consumed by execute(), stamped onto the tracked app
                self.openIPA(ipa)                      // normal inspect → device picker → install flow
            } catch { self.status = "Download failed: \(error.localizedDescription)" }
        }
    }

    func searchGitHub() {
        let q = githubQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        githubSearching = true; githubResults = []; githubSearchNote = "Searching…"; githubOfferToken = false
        Task { @MainActor in
            let hits = await GitHub.searchReposWithIPA(q)
            self.githubResults = hits
            self.githubSearching = false
            if !hits.isEmpty { self.githubSearchNote = ""; return }
            // Empty could mean genuinely nothing, or the hourly core budget is spent
            // (each search probes ~20 repos; unauthenticated GitHub allows only 60/hr).
            let remaining = await GitHub.coreRemaining()
            if let r = remaining, r < 3 {
                if GitHub.hasToken {
                    self.githubSearchNote = "GitHub's hourly request limit is used up even with your saved token (5000/hour). That's unusual — wait a few minutes and try again, or use “Install from GitHub” by owner/name."
                } else {
                    self.githubSearchNote = "GitHub's hourly request limit is used up (only 60/hour without a sign-in, and each search checks up to 20 repos). Add a free GitHub token to raise this to 5000/hour, or wait a while — or if you know the app's repo, use “Install from GitHub” by owner/name, which barely uses the limit."
                    self.githubOfferToken = true
                }
            } else {
                self.githubSearchNote = "No repositories with an .ipa release matched “\(q)”. (GitHub can't search release files, so this only matches repo names/descriptions — “Install from GitHub” by owner/name is more reliable.)"
            }
        }
    }

    /// Ask for a GitHub personal-access token and save it to the Keychain. Offers a
    /// button that opens the token-creation page, verifies the token before saving,
    /// and (on success) re-runs the last search so the user sees results immediately.
    func promptGitHubToken(rerunQuery: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = GitHub.hasToken ? "Update your GitHub token" : "Add a GitHub token"
        a.informativeText = "A GitHub personal-access token raises the search limit from 60 to 5000 requests/hour. A read-only token with no extra scopes is enough (public-repo read).\n\nClick “Create a token…” to open GitHub, generate one, then paste it here."
        // Plain (not secure) + wide: a github_pat_ token is ~90 chars, so the field
        // must be roomy enough to show the whole paste — a narrow secure field showed
        // only a few dots and looked like the paste had failed.
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 620, height: 24))
        tf.placeholderString = "ghp_…  or  github_pat_…  (paste the full token)"
        tf.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tf.lineBreakMode = .byTruncatingTail
        a.accessoryView = tf
        a.addButton(withTitle: "Save")            // .alertFirstButtonReturn
        a.addButton(withTitle: "Create a token…") // .alertSecondButtonReturn
        a.addButton(withTitle: "Cancel")
        if GitHub.hasToken { a.addButton(withTitle: "Remove saved token") }
        a.window.initialFirstResponder = tf
        let resp = a.runModal()
        switch resp {
        case .alertSecondButtonReturn:
            if let u = URL(string: GitHub.createTokenURL) { NSWorkspace.shared.open(u) }
            // Re-open the entry sheet so they can paste after creating the token.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.promptGitHubToken(rerunQuery: rerunQuery) }
        case .alertThirdButtonReturn:
            return   // Cancel
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            GitHub.clearToken(); githubHasToken = false; status = "Removed the saved GitHub token."
        default:   // Save
            let entered = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entered.isEmpty else { return }
            status = "Verifying GitHub token…"
            Task { @MainActor in
                if let login = await GitHub.verifyToken(entered) {
                    GitHub.saveToken(entered)
                    self.githubHasToken = true; self.githubOfferToken = false
                    self.status = "Saved GitHub token for \(login)."
                    if let q = rerunQuery, !q.isEmpty { self.githubQuery = q; self.searchGitHub() }
                } else {
                    self.status = "That GitHub token didn't work — check you copied it fully and it isn't expired."
                    let retry = NSAlert()
                    retry.messageText = "Token not accepted"
                    retry.informativeText = "GitHub rejected that token. It may be mistyped, expired, or lack read access. Try again?"
                    retry.addButton(withTitle: "Try again"); retry.addButton(withTitle: "Cancel")
                    if retry.runModal() == .alertFirstButtonReturn { self.promptGitHubToken(rerunQuery: rerunQuery) }
                }
            }
        }
    }

    /// Bare-username install: show that user's repos that publish an .ipa, in the
    /// GitHub results window, so the user can pick which to install.
    func installFromGitHubUser(_ user: String) {
        githubSearching = true; githubResults = []; githubSearchNote = "Finding \(user)'s apps on GitHub…"; githubOfferToken = false
        showGitHubSearchWindow()
        Task { @MainActor in
            let hits = await GitHub.userReposWithIPA(user)
            self.githubResults = hits; self.githubSearching = false
            if !hits.isEmpty { self.githubSearchNote = "" ; return }
            let remaining = await GitHub.coreRemaining()
            if (remaining ?? 99) < 3 {
                if GitHub.hasToken {
                    self.githubSearchNote = "GitHub's hourly limit is used up even with your saved token — wait a few minutes and try again."
                } else {
                    self.githubSearchNote = "GitHub's hourly request limit is used up (60/hour without a sign-in). Add a free GitHub token to raise it to 5000/hour, or wait a while and try again."
                    self.githubOfferToken = true
                }
            } else {
                self.githubSearchNote = "No public repositories with an .ipa release were found for “\(user)”."
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
        // Empty query → all apps (AltStoreCatalog.search returns everything).
        altStoreResults = AltStoreCatalog.search(altStoreQuery, in: altStoreAllApps)
        if altStoreResults.isEmpty && !altStoreLoading && !altStoreAllApps.isEmpty {
            altStoreNote = "No apps match “\(altStoreQuery)”."
        }
    }
    func installAltStoreApp(_ app: SourceApp) { closeAltStoreSearch(); startInstall(.source(app)) }
    func reloadAltStoreSources() { Task { @MainActor in self.altStoreSources = await AltStoreCatalog.effectiveSources() } }
    func addAltStoreSource(_ url: String) {
        if let note = Blocklist.shared.blockedSource(url) {
            let a = NSAlert()
            a.messageText = "SideStep won't add this source"
            a.informativeText = "That source is on SideStep's block list because it distributes pirated or cracked apps.\n\n\(note)"
            a.alertStyle = .warning; a.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true); a.runModal()
            status = "Blocked a known pirate source."
            return
        }
        AltStoreCatalog.addUserSource(url); reloadAltStoreSources(); loadAltStore(force: true)
    }
    func removeAltStoreSource(_ url: String) { AltStoreCatalog.removeSource(url); reloadAltStoreSources(); loadAltStore(force: true) }

    /// Manually check every GitHub-tracked app for a newer release now.
    func checkGitHubUpdatesNow() {
        status = "Checking GitHub apps for updates…"
        Task.detached { [weak self] in
            await Sideloader.checkGitHubUpdates(log: { print("[SideStep github] \($0)") })
            await MainActor.run { self?.tracked = Tracked.all(); self?.status = "GitHub update check complete." }
        }
    }

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
        // Refresh the tapped app — and, since we're already reaching this device,
        // sweep up any OTHER apps on it whose signature has ALREADY expired, so a
        // single tap recovers a device that sat dead past the 7-day window.
        let devName = t.deviceName.isEmpty ? "device" : t.deviceName
        let expiredSiblings = Tracked.all().filter {
            $0.udid == t.udid && $0.id != t.id && ($0.secondsUntilExpiry ?? 1) <= 0
        }
        let queue = [t] + expiredSiblings
        installing = true
        status = queue.count > 1 ? "Refreshing \(queue.count) apps on \(devName)…"
                                 : "Refreshing \(t.name) on \(devName)…"
        // Same live progress/result popup as a first install, so the outcome (and any
        // real error) is visible without scrolling the menu to the status line.
        beginInstallProgress(title: queue.count > 1
            ? "Refreshing \(queue.count) apps on \(devName)"
            : "Refreshing “\(t.name)”\(devName == "device" ? "" : " on \(devName)")")
        Task.detached { [weak self] in
            guard let self else { return }
            let log: @Sendable (String) -> Void = { m in
                print("[SideStep] \(m)")
                let line = String(m.split(separator: "\n").first.map(String.init)?.prefix(160) ?? "")
                Task { @MainActor in
                    self.status = line
                    if !line.isEmpty { self.ipStatus = line }
                    if !line.contains("Downloading") { self.clearDownloadProgress() }
                }
            }
            let onProgress: @Sendable (Int64, Int64) -> Void = { received, total in
                Task { @MainActor in self.reportDownload(received: received, total: total) }
            }
            let onInstall: @Sendable (Int, String) -> Void = { percent, phase in
                Task { @MainActor in self.reportInstallProgress(percent: percent, phase: phase) }
            }
            var ok = 0, fail = 0, last = "", lastErr = ""
            for app in queue {
                do { last = try await Sideloader.refreshOne(app, log: log, onProgress: onProgress, onInstall: onInstall); ok += 1 }
                catch { fail += 1; lastErr = error.localizedDescription; print("[SideStep] refresh failed for \(app.name): \(error)") }
            }
            let ok2 = ok, fail2 = fail
            await MainActor.run {
                let msg: String
                if queue.count > 1 {
                    msg = fail2 == 0 ? "Refreshed \(ok2) apps on \(devName)."
                                     : "Refreshed \(ok2) of \(queue.count) on \(devName) — \(fail2) failed."
                } else {
                    msg = fail2 == 0 ? last : "Refresh failed: \(t.name) — \(lastErr)"
                }
                self.status = msg
                self.finishInstallProgress(ok: fail2 == 0, message: msg)
                self.tracked = Tracked.all(); self.installing = false
            }
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
    @State private var didSeedCollapse = false   // one-time: start every app's device list collapsed

    /// On first load, collapse the device list under every app so the popover opens
    /// compact (one row per app). Runs once; the user's later expand/collapse and any
    /// app installed mid-session are left alone (a new install shows expanded).
    private func seedCollapsedApps() {
        guard !didSeedCollapse, !m.tracked.isEmpty else { return }
        didSeedCollapse = true
        collapsedApps = Set(m.tracked.map { "\($0.appleID)/\($0.origBundleID)" })
    }

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
                                        let devLabel = !t.deviceName.isEmpty ? t.deviceName
                                            : (DeviceIPCache.name(for: t.udid) ?? t.udid)
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
                    Text("Create free Apple accounts at [icloud.com](https://www.icloud.com/) — each free account can install **3 apps**. A $99/year Apple Developer subscription removes the limit.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Button(m.githubHasToken ? "GitHub token (saved) — change…" : "Add a GitHub token (faster search)…") { m.promptGitHubToken() }
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
        .onAppear { m.loadAccountInfo(); seedCollapsedApps() }
        .onChange(of: m.tracked.count) { _, _ in seedCollapsedApps() }   // seed once tracked apps load in
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
    @FocusState private var filterFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install apps from AltStore sources").font(.headline)
            Text("Browse and filter curated AltStore catalogs (open-source apps, emulators, official apps). Plain source JSON — no GitHub rate limits. These are apps distributed as sideloadable .ipa files; App Store apps and EU-marketplace apps (e.g. Fortnite via Epic/AltStore PAL) aren’t here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("filter apps by name…", text: $m.altStoreQuery).textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .onChange(of: m.altStoreQuery) { _ in m.filterAltStore() }
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { filterFocused = true } }
                    // The catalog load re-renders the list and drops focus, so re-assert it
                    // once loading finishes (and any time it flips back to idle).
                    .onChange(of: m.altStoreLoading) { loading in
                        if !loading { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { filterFocused = true } }
                    }
                if m.altStoreLoading { ProgressView().scaleEffect(0.6).frame(width: 14, height: 14) }
                Button("Reload") { m.loadAltStore(force: true) }.disabled(m.altStoreLoading)
            }
            Text(m.altStoreLoading ? "Loading catalog…"
                 : m.altStoreQuery.trimmingCharacters(in: .whitespaces).isEmpty
                   ? "Showing all \(m.altStoreResults.count) apps across \(m.altStoreSources.count) sources — type to filter."
                   : "\(m.altStoreResults.count) app\(m.altStoreResults.count == 1 ? "" : "s") match “\(m.altStoreQuery)”.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if m.altStoreResults.isEmpty {
                        Text(m.altStoreLoading ? "Loading catalog…" : m.altStoreNote)
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(m.altStoreResults) { app in
                        HStack(alignment: .top, spacing: 8) {
                            AsyncImage(url: app.iconURL.flatMap { URL(string: $0) }) { img in img.resizable() }
                                placeholder: { RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.15)) }
                                .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(app.name).font(.callout.weight(.medium))
                                        .foregroundStyle(app.infoURL != nil ? Color.accentColor : Color.primary)
                                    if let v = app.version, !v.isEmpty { Text("v\(v)").font(.caption2).foregroundStyle(.secondary) }
                                }
                                if let d = app.localizedDescription, !d.isEmpty {
                                    Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }
                                Text(app.sourceName).font(.caption2).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if let u = app.infoURL { NSWorkspace.shared.open(u) } }
                            .onHover { h in if app.infoURL != nil { if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } } }
                            .help(app.infoURL.map { "More info: \($0.absoluteString)" } ?? "")
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
                    Text("Add legitimate AltStore-format source URLs. The default list lives in SideStep’s repo ([sources.json](https://github.com/johnbuckman/SideStep/blob/main/sources.json)) — send a PR to add to it.")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
            }.font(.callout)
            HStack { Spacer(); Button("Done") { m.closeAltStoreSearch() } }
        }
        .padding(16).frame(width: 520, height: 580)
    }
}

/// Live install progress + final outcome, shown in its own window so the result is
/// always visible without reopening SideStep.
/// A solid filled-capsule button. macOS 26's prominent/default ("Liquid Glass") style,
/// when hosted in the install-progress NSWindow, rendered the accent fill hugging the label
/// inside a wider translucent track — so the button "didn't fill its border". This style
/// draws one solid accent capsule that always fills, with a pressed dim. Enter still works
/// because the call site keeps `.keyboardShortcut(.defaultAction)`.
struct SolidCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 8)
            .frame(minWidth: 84)
            .background(Capsule().fill(Color.accentColor))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

struct InstallProgressView: View {
    @ObservedObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(m.ipTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
            if m.ipDone {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: m.ipOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(m.ipOK ? .green : .red).font(.title2)
                    if m.ipOK {
                        Text(m.ipResult.isEmpty ? "Installed." : m.ipResult)
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    } else {
                        // A failure can carry a long installd error — show it in full:
                        // wrapping, selectable (so it can be copied), and scrollable past a
                        // few lines so nothing is clipped.
                        ScrollView(.vertical) {
                            Text(m.ipResult.isEmpty ? "Install failed." : m.ipResult)
                                .font(.callout).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                    }
                }
            } else if let p = m.ipProgress {
                // Determinate download: a real bar with % · size · ETA underneath.
                VStack(alignment: .leading, spacing: 6) {
                    Text(m.ipStatus).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: p).progressViewStyle(.linear)
                    if !m.ipDetail.isEmpty {
                        Text(m.ipDetail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                        Text(m.ipStatus).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Downloads with no Content-Length can't show a bar; still surface bytes-so-far.
                    if !m.ipDetail.isEmpty {
                        Text(m.ipDetail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            HStack {
                Spacer()
                Button(m.ipDone ? "OK" : "Hide") { m.closeInstallProgress() }
                    .buttonStyle(SolidCapsuleButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: m.ipDone && !m.ipOK ? 560 : 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)   // adopt full height so nothing clips
    }
}

/// Landing window for a sidestep://install?repo=… deep link. Names the repo, shows
/// its newest .ipa release, and waits for the user to tap Install — a URL never
/// installs on its own.
struct GitHubConfirmView: View {
    @ObservedObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install from GitHub").font(.headline)
            HStack(spacing: 8) {
                Image(systemName: "shippingbox").foregroundStyle(.tint)
                Text(m.confirmRepo).font(.body.monospaced()).textSelection(.enabled)
            }
            if m.confirmChecking {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                    Text("Checking latest release…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text(m.confirmReleaseLine).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warn = m.confirmTokenWarning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Your saved GitHub token was rejected, so SideStep is using unauthenticated access (60 requests/hour). GitHub says:\n“\(warn)”")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button("Fix GitHub token…") { if let u = URL(string: GitHub.createTokenURL) { NSWorkspace.shared.open(u) } }
                        Button("Remove saved token") { GitHub.saveToken(""); m.githubHasToken = false; m.confirmTokenWarning = nil }
                    }.font(.caption)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
            }
            HStack {
                Spacer()
                Button("Cancel") { m.closeGitHubConfirm() }.keyboardShortcut(.cancelAction)
                Button("Install") { m.confirmGitHubInstall() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440, alignment: .leading)
    }
}

/// Popover-safe "Add an Apple ID" window — shown when an install (e.g. a first-time
/// sidestep:// deep-link) needs an account and none is signed in. Same fields as the
/// in-panel sign-in form; on success the pending install resumes automatically.
struct AddAccountView: View {
    @ObservedObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an Apple ID").font(.headline)
            Text("Installing needs an Apple ID to sign the app onto your device. Any Apple ID works — a free one is fine.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Button("Cancel") { m.cancelAddAccount() }.keyboardShortcut(.cancelAction)
                if m.loginStage == .working { ProgressView().scaleEffect(0.6).frame(width: 14, height: 14) }
                Text(m.loginStatus).font(.caption).foregroundStyle(.red)
            }
            Text("Create free Apple accounts at [icloud.com](https://www.icloud.com/) — each free account can install **3 apps**. A $99/year Apple Developer subscription removes the limit.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 420, alignment: .leading)
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
                        if m.githubOfferToken {
                            Button("Add a GitHub token…") { m.promptGitHubToken(rerunQuery: m.githubQuery) }
                                .padding(.top, 4)
                        }
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
/// routing them into the same install dialog as the in-app "Install from .ipa…" button.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            if u.scheme?.lowercased() == "sidestep" {
                Task { @MainActor in AppModel.shared.handleURLScheme(u) }
            } else if u.pathExtension.lowercased() == "ipa" {
                Task { @MainActor in AppModel.shared.openIPA(u.path) }
            }
        }
    }

    // Lifecycle instrumentation — the app on some Macs quit cleanly right after
    // init() with no crash report. These log exactly how far past init it gets
    // and whether it terminates via the normal AppKit path (delegate fires) or is
    // killed (no willTerminate line). Crash-safe /tmp log, so it survives.
    func applicationDidFinishLaunching(_ n: Notification) {
        CrashLog.log("app: applicationDidFinishLaunching (activationPolicy=\(NSApp.activationPolicy().rawValue), windows=\(NSApp.windows.count))")
        reapOrphanedHelpers()   // clear stale device helpers before we touch any device
        // Belt-and-braces: a menu-bar-only app must be .accessory, not .prohibited.
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }
    /// Kill orphaned device helpers left over from a previous session. When SideStep
    /// quits or is force-killed mid-install, its idevice_ipinstall/idevicehelper child
    /// is reparented to launchd and keeps running — holding the device's AFC /
    /// installation_proxy / heartbeat session, which then WEDGES the next launch's
    /// install of that device (the failure seen 2026-08-11: a stale ipinstall to a
    /// Wi-Fi device jammed the app so its menu wouldn't even open). At startup we have
    /// spawned no helpers of our own yet, so any running bundled helper is, by
    /// definition, a stale orphan and safe to reap. (Child-side getppid guards in the
    /// helpers are the belt to this braces — they self-exit when reparented.)
    private func reapOrphanedHelpers() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "/Contents/Helpers/idevice/"]   // only our bundled device tools
        do {
            try p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 { CrashLog.log("startup: reaped orphaned device helper(s) from a prior session") }
        } catch { CrashLog.log("startup: reapOrphanedHelpers failed: \(error)") }
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
            dlog("post-launch: starting LAN services (only if there are apps to serve)…")
            LANServices.startIfNeeded()   // gated so a fresh SideStep never triggers the Local Network prompt
            dlog("post-launch: LAN services evaluated")
            UpdateChecker.shared.checkIfDue()   // daily GitHub-Releases self-update check
            Task { await Blocklist.refresh() }  // pull the latest anti-piracy blocklist from the repo
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
        .frame(width: 470, height: min(max(contentHeight, 120) * 1.5, maxHeight))   // 50% taller
        .onPreferenceChange(ContentHeightKey.self) { h in
            if h > 1 { contentHeight = h }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)   // pure-white page, readable in dark mode too
        .focusEffectDisabled()                // kill the stray blue focus ring at the window level too
    }
}
