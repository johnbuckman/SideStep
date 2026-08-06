//
//  SideStep Installer — a minimal, standalone one-click installer.
//
//  It is NOT SideStep and ships no copy of it. Named "Install owner--repo.app" (the
//  "--" is the encoded "/"), it: downloads the latest SideStep from GitHub Releases and
//  installs it, walks the user through readying their iPhone/iPad (verifying each step
//  for real over USB via SideStep's own device tools), then opens
//  sidestep://install?repo=owner/repo so they just tap Install.
//
//  It has its OWN bundle id (com.johnbuckman.sidestep.installer), distinct from
//  SideStep's — so macOS never confuses the two: the wizard always runs (even when
//  SideStep is already installed), and the sidestep:// handoff routes unambiguously to
//  the installed SideStep.
//

import SwiftUI
import AppKit

enum WizardStep: Int, CaseIterable {
    case welcome        // explain what will happen
    case installApp     // download + install the latest SideStep
    case connect        // wait for a USB-connected device
    case trust          // wait for "Trust This Computer"
    case devMode        // enable Developer Mode (may reboot)
    case ready          // hand off to sidestep://install?repo=…
}

@MainActor
final class Wizard: ObservableObject {
    let token: InstallToken     // from the filename: an explicit owner/repo, or a tiny alias
    private var resolvedRepo: String?   // set once known (immediately, or after tinyurl lookup)

    @Published var step: WizardStep = .welcome
    @Published var detail = ""
    @Published var busy = false
    @Published var failed = false                 // install step hit an error; offer Retry
    @Published var device: (udid: String, name: String, conn: String)?
    @Published var devModeNeedsManual = false

    private var sideStepApp: URL?
    private var tool: DeviceTool?
    private var pollTimer: Timer?
    private var sawDeviceBeforeReboot = false

    init(token: InstallToken) {
        self.token = token
        if case .repo(let r) = token { resolvedRepo = r }
    }

    /// User-facing name (available immediately from the filename, no network).
    var repoDisplay: String { token.display }

    // MARK: navigation

    func begin() { advance(to: .installApp) }

    func advance(to next: WizardStep) {
        step = next; detail = ""; failed = false
        stopPolling()
        switch next {
        case .welcome, .ready: break
        case .installApp: runDownloadInstall()
        case .connect, .trust: startPolling()
        case .devMode: startDevMode()
        }
    }

    // MARK: step 2 — download + install SideStep

    func runDownloadInstall() {
        busy = true; failed = false; detail = "Preparing…"
        Task {
            // Resolve the filename token → owner/repo before installing.
            if resolvedRepo == nil {
                switch token {
                case .repo(let r):
                    resolvedRepo = r
                case .id(let id, let disp):
                    detail = "Looking up \(disp)…"
                    guard let r = await GitHubID.resolve(id) else {
                        self.busy = false; self.failed = true
                        self.detail = "Couldn’t find this app on GitHub. Check your internet connection and try again."
                        return
                    }
                    resolvedRepo = r
                case .alias(let a):
                    detail = "Looking up \(a)…"
                    guard let r = await TinyURL.resolve(a) else {
                        self.busy = false; self.failed = true
                        self.detail = "Couldn’t find “\(a)”. Make sure tinyurl.com/\(a) points to a GitHub repo."
                        return
                    }
                    resolvedRepo = r
                }
            }
            let result = await Downloader.ensureSideStep { msg in
                Task { @MainActor in if self.step == .installApp { self.detail = msg } }
            }
            self.busy = false
            switch result {
            case .installed(let url):
                self.sideStepApp = url
                self.tool = DeviceTool(sideStepApp: url)
                self.detail = "SideStep is installed."
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if self.step == .installApp { self.advance(to: .connect) }
                }
            case .failure(let msg):
                self.failed = true
                self.detail = msg
            }
        }
    }

    // MARK: steps 3–5 — live device polling (via SideStep's installed tools)

    private func startPolling() {
        poll()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }
    private func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    private func startDevMode() {
        sawDeviceBeforeReboot = false; devModeNeedsManual = false
        if let udid = device?.udid { _ = tool?.revealDeveloperMode(udid) }
        startPolling()
    }

    private func poll() {
        guard let tool else { return }
        let devices = tool.connectedDevices()
        let usb = devices.first(where: { $0.conn == "usb" }) ?? devices.first
        device = usb

        switch step {
        case .connect:
            if let d = usb {
                detail = "Found \(d.name == d.udid ? "a device" : d.name) over USB."
                advance(to: .trust)
            } else { detail = "Waiting for a device on USB…" }

        case .trust:
            guard let d = usb else { detail = "Device disconnected — plug it back in."; advance(to: .connect); return }
            if d.name != d.udid { detail = "Trusted: \(d.name)."; advance(to: .devMode) }
            else { detail = "On the device, tap “Trust” and enter its passcode…" }

        case .devMode:
            guard let d = usb else {
                sawDeviceBeforeReboot = true
                detail = "The device is restarting to turn on Developer Mode…"; return
            }
            if sawDeviceBeforeReboot { detail = "Device is back. Unlock it and confirm Developer Mode if asked…" }
            switch tool.developerMode(d.udid) {
            case .enabled:     detail = "Developer Mode is on."; advance(to: .ready)
            case .unsupported: detail = "This device doesn’t require Developer Mode."; advance(to: .ready)
            case .disabled, .unknown:
                if !busy && !devModeNeedsManual { detail = "Turning on Developer Mode…" }
            }
        default: break
        }
    }

    func enableDeveloperMode() {
        guard let udid = device?.udid, let tool else { return }
        busy = true; detail = "Asking the device to enable Developer Mode…"
        Task.detached {
            let r = tool.tryEnableDeveloperMode(udid)
            await MainActor.run {
                self.busy = false
                switch r {
                case .enabled:   self.detail = "Developer Mode enabled."
                case .rebooting: self.detail = "The device is restarting. Unlock it, then tap “Turn On”."
                case .needsManual, .unknown:
                    self.devModeNeedsManual = true
                    self.detail = DeviceTool.developerModeHelp
                }
            }
        }
    }

    // MARK: step 6 — hand off to the installed SideStep

    func handOff() {
        wlog("handOff: resolvedRepo=\(resolvedRepo ?? "nil") sideStepApp=\(sideStepApp?.path ?? "nil")")
        guard let app = sideStepApp, let repo = resolvedRepo else {
            wlog("handOff: MISSING state — cannot hand off; quitting")
            NSApp.terminate(nil); return
        }
        let encoded = repo.addingPercentEncoding(withAllowedCharacters: .ssURLQueryValueAllowed) ?? repo
        if let url = URL(string: "sidestep://install?repo=\(encoded)") {
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            wlog("handOff: opening \(url.absoluteString) via \(app.path)")
            // Deliver to the installed SideStep specifically. (Our bundle id differs, so
            // scheme resolution wouldn't come back to us — but being explicit is safest.)
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { running, err in
                wlog("handOff: open completion running=\(running != nil) err=\(err?.localizedDescription ?? "none")")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
    }
}

extension CharacterSet {
    static let ssURLQueryValueAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics; s.insert(charactersIn: "-._~"); return s
    }()
}

// MARK: - Two modes, chosen by the app's own filename

enum AppMode {
    case developer                  // "SideStepWizard.app" — configure + emit an installer
    case endUser(token: InstallToken) // "Install …app" — run the install wizard
}

/// What the installer's filename carries, in priority order:
///   "<name> installer (<id>)"  → a GitHub repo id, resolved via the API (preferred)
///   "owner--repo installer"    → an explicit owner/repo (offline)
///   "<alias> installer"        → a tinyurl alias (legacy)
enum InstallToken {
    case id(Int, display: String)   // GitHub repo id → resolve via api.github.com/repositories/<id>
    case repo(String)               // "owner/repo"
    case alias(String)              // "magnatune-app" → resolve via tinyurl.com/magnatune-app
    var display: String {
        switch self {
        case .id(_, let d): return d
        case .repo(let r):  return RepoName.display(r)
        case .alias(let a): return a
        }
    }
}

enum RepoName {
    /// Parse the installer's filename. Preferred form is "<name> installer (<base62 id>)"
    /// (name first, so it survives truncation). Legacy forms "<stem> installer" /
    /// "Install <stem>" (owner--repo or tinyurl alias) are still accepted.
    static func token(fromInstallFilename base: String) -> InstallToken? {
        let s = base.trimmingCharacters(in: .whitespaces)
        // Preferred: a trailing "(<base62 id>)" → GitHub repo id.
        if let p = s.range(of: "\\(([0-9A-Za-z]+)\\)$", options: .regularExpression) {
            let code = String(s[p].dropFirst().dropLast())          // inside the parens
            if let id = Base62.decode(code) {
                let namePart = String(s[..<p.lowerBound]).trimmingCharacters(in: .whitespaces)
                let disp = stem(of: namePart) ?? (namePart.isEmpty ? "your app" : namePart)
                return .id(id, display: disp)
            }
        }
        // Legacy: strip " installer" suffix / "Install " prefix → owner--repo or alias.
        guard let t = stem(of: s), !t.isEmpty else { return nil }
        if let r = t.range(of: "--") {
            let owner = String(t[..<r.lowerBound]); let repo = String(t[r.upperBound...])
            guard !owner.isEmpty, !repo.isEmpty else { return nil }
            return .repo("\(owner)/\(repo)")
        }
        guard !t.contains("/") else { return nil }
        return .alias(t)
    }
    /// Strip a " installer" suffix or an "Install " prefix; nil if neither is present.
    private static func stem(of s: String) -> String? {
        let lower = s.lowercased()
        if lower.hasSuffix(" installer") { return String(s.dropLast(" installer".count)).trimmingCharacters(in: .whitespaces) }
        if lower.hasPrefix("install ")   { return String(s.dropFirst("install ".count)).trimmingCharacters(in: .whitespaces) }
        return nil
    }
    /// "<display>" + GitHub id → "<display> installer (<base62 id>)" (preferred form).
    static func installFilename(display: String, id: Int) -> String {
        "\(display) installer (\(Base62.encode(id)))"
    }
    /// "owner/repo" → filename stem "owner--repo installer" (offline form).
    static func installFilename(for repo: String) -> String {
        repo.replacingOccurrences(of: "/", with: "--") + " installer"
    }
    /// "alias" → filename stem "alias installer" (tinyurl form; legacy).
    static func installFilename(alias: String) -> String { alias + " installer" }
    /// Friendly name shown to users — the repo's last path component.
    static func display(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }
    /// Accepts "owner/repo" or a github.com URL; returns a clean "owner/repo" or nil.
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://github.com/", "http://github.com/", "github.com/"] {
            if s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = s.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}

func detectMode() -> AppMode {
    let base = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    if let token = RepoName.token(fromInstallFilename: base) { return .endUser(token: token) }
    return .developer
}

@main
struct SideStepWizardApp: App {
    private let mode = detectMode()
    var body: some Scene {
        Window(windowTitle, id: "main") {
            switch mode {
            case .developer:           DeveloperView()
            case .endUser(let token):  EndUserWizard(token: token)
            }
        }
        .windowResizability(.contentSize)
    }
    private var windowTitle: String {
        switch mode {
        case .developer:          return "SideStep Wizard"
        case .endUser(let token): return "Install \(token.display) with SideStep"
        }
    }
}

/// Holds the Wizard as a @StateObject so it survives SwiftUI re-renders of the Window
/// body — otherwise the Wizard (and its resolved repo / installed SideStep path) could be
/// silently recreated mid-flow, breaking the final hand-off.
struct EndUserWizard: View {
    @StateObject private var w: Wizard
    init(token: InstallToken) { _w = StateObject(wrappedValue: Wizard(token: token)) }
    var body: some View { WizardView(w: w) }
}

/// Crash-safe diagnostic log for the installer wizard.
func wlog(_ s: String) {
    let line = "[wizard] \(s)\n"
    let path = "/tmp/sidestep.log"
    if let h = FileHandle(forWritingAtPath: path) {
        defer { try? h.close() }
        h.seekToEndOfFile(); h.write(Data(line.utf8))
    } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

// MARK: - Base62 (compact GitHub-id encoding for filenames)

enum Base62 {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static func encode(_ n: Int) -> String {
        guard n > 0 else { return "0" }
        var v = n, out = [Character]()
        while v > 0 { out.append(alphabet[v % 62]); v /= 62 }
        return String(out.reversed())
    }
    static func decode(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        var v = 0
        for ch in s {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            v = v * 62 + i
        }
        return v
    }
}

// MARK: - GitHub repo-id resolution (no shortener needed; ids are immutable)

enum GitHubID {
    /// GitHub numeric repo id → "owner/repo", via api.github.com/repositories/<id>.
    static func resolve(_ id: Int) async -> String? {
        await fullName(URL(string: "https://api.github.com/repositories/\(id)"))
    }
    /// "owner/repo" → its numeric id (used by the wizard when building an installer).
    static func idFor(_ repo: String) async -> Int? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)") else { return nil }
        return await json(url)?["id"] as? Int
    }
    private static func fullName(_ url: URL?) async -> String? {
        guard let url else { return nil }
        return await json(url)?["full_name"] as? String
    }
    private static func json(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SideStep", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - TinyURL (no-auth): resolve an alias, and register a new one

enum TinyURL {
    /// tinyurl.com/<alias> → "owner/repo", or nil if it doesn't resolve to a GitHub repo.
    static func resolve(_ alias: String) async -> String? {
        guard let url = URL(string: "https://tinyurl.com/\(alias)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")   // tinyurl 403s empty UAs
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let final = resp.url, final.host?.contains("github.com") == true
        else { return nil }
        return RepoName.normalize(final.absoluteString)
    }

    enum RegisterResult { case ok, alreadySameTarget, taken(existing: String), failed(String) }

    /// Create tinyurl.com/<alias> → <githubURL> with the no-auth endpoint. Idempotent:
    /// if the alias already points at the same repo we report .alreadySameTarget; if it
    /// points elsewhere we report .taken so the developer can choose another name.
    static func register(alias: String, githubURL: String, repo: String) async -> RegisterResult {
        // Already taken?
        if let existing = await resolve(alias) {
            return existing == repo ? .alreadySameTarget : .taken(existing: existing)
        }
        let enc = githubURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? githubURL
        let aliasEnc = alias.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? alias
        guard let create = URL(string: "https://tinyurl.com/api-create.php?url=\(enc)&alias=\(aliasEnc)") else {
            return .failed("bad URL")
        }
        var req = URLRequest(url: create)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let body = String(data: data, encoding: .utf8) else { return .failed("no response from tinyurl") }
        // Success returns the short URL; errors return a message that isn't our alias.
        guard body.contains("tinyurl.com/\(alias)") else {
            return .failed(body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Confirm it resolves to the intended repo.
        if await resolve(alias) == repo { return .ok }
        return .failed("created, but it didn’t resolve to \(repo)")
    }
}
