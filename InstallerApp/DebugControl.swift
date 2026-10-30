// Debug control channel for the Mac app — the Mac-side twin of the beacon's token-gated
// debug port (BeaconInject/beacon_inject.m). Lets a script (the regression harness, or an
// agent making screenshots / an explainer video) open every window, prompt and dialog,
// fill fields, press buttons and snapshot SideStep's own windows, with no mouse.
//
// OFF unless a token is configured: env SIDESTEP_DEBUG_TOKEN, or the file
// ~/Library/Application Support/SideStep/debug-token (must be chmod 600). Release builds
// carry the code but never listen without that file. Listens on 127.0.0.1 only.
//
// Wire protocol (TCP 127.0.0.1:51238), one command per line, any number per connection:
//   <token> CMD [args…]          args are space-separated; "double quotes" group words
// Each command gets exactly one reply line: JSON for queries, "OK …" or "ERR …" otherwise.
// Commands that open a modal alert reply first and then open it (a modal would otherwise
// block the reply); use ALERT / WINDOWS to see what appeared. Full list: HELP.
import AppKit
import Network
import SwiftUI
import SideloaderKit

@MainActor enum DebugControl {
    static let port: UInt16 = 51238
    private static var listener: NWListener?
    nonisolated(unsafe) private static var token = ""

    static var tokenFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SideStep/debug-token")
    }
    nonisolated static var snapDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SideStep/debug-snaps")
    }

    /// Start the listener if (and only if) a debug token is configured.
    static func startIfConfigured() {
        guard listener == nil else { return }
        var t = ProcessInfo.processInfo.environment["SIDESTEP_DEBUG_TOKEN"] ?? ""
        if t.isEmpty, let attrs = try? FileManager.default.attributesOfItem(atPath: tokenFile.path) {
            // refuse a token file other users could read
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            if perms & 0o077 != 0 { dlog("debug control: \(tokenFile.path) must be chmod 600 — not starting"); return }
            t = ((try? String(contentsOf: tokenFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !t.isEmpty else { return }
        token = t
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { c in Session(c).start() }
            l.stateUpdateHandler = { st in dlog("debug control: \(st)") }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
            dlog("debug control: listening on 127.0.0.1:\(port)")
        } catch { dlog("debug control: couldn't listen: \(error)") }
        DeviceRelay.start(token: t)
    }

    /// One client connection: read lines, answer each in order.
    private final class Session: @unchecked Sendable {
        let c: NWConnection
        var buf = Data()
        init(_ c: NWConnection) { self.c = c }
        func start() { c.start(queue: .global(qos: .userInitiated)); read() }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, err in
                if let data { buf.append(data) }
                drain()   // on this connection's background queue; commands hop to the main thread one by one
                if done || err != nil { c.cancel() } else { read() }
            }
        }
        func drain() {
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
                buf.removeSubrange(buf.startIndex...nl)
                let reply = DebugControl.dispatch(line.trimmingCharacters(in: .whitespacesAndNewlines))
                let out = reply.replacingOccurrences(of: "\n", with: " ") + "\n"
                let sent = DispatchSemaphore(value: 0)
                c.send(content: out.data(using: .utf8), completion: .contentProcessed { _ in sent.signal() })
                sent.wait()
            }
        }
    }

    // MARK: getting onto the main thread — even while an NSAlert is up
    //
    // SideStep opens its alerts with runModal() from inside main-queue work (DispatchQueue /
    // MainActor tasks). While one is up the main *queue* is blocked behind it, so neither
    // DispatchQueue.main nor a MainActor Task would ever run a command. Run-loop blocks
    // registered for the modal-panel mode do run inside runModal's loop, so every command
    // (and every deferred action) reaches the main thread that way instead.
    nonisolated static let modes = [CFRunLoopMode.defaultMode.rawValue,
                                    "NSModalPanelRunLoopMode" as CFString,
                                    "NSEventTrackingRunLoopMode" as CFString] as CFArray
    nonisolated static func onMain<T>(_ f: @escaping @MainActor () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var r: T?
        CFRunLoopPerformBlock(CFRunLoopGetMain(), modes) { MainActor.assumeIsolated { r = f() }; done.signal() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        done.wait()
        return r!
    }
    /// Run on the main thread soon, without waiting (for actions that open a modal alert).
    nonisolated static func mainSoon(_ f: @escaping @MainActor () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), modes) { MainActor.assumeIsolated { f() } }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// Entry point from a connection (background thread). TYPE runs here so its pauses
    /// between letters don't hold the main thread; everything else runs on main.
    nonisolated static func dispatch(_ line: String) -> String {
        var w = split(line)
        guard w.count >= 2, w.removeFirst() == token else { return "ERR auth" }
        let cmd = w.removeFirst().uppercased()
        if cmd == "DEVICES" { return json(DeviceRelay.list()) }
        if cmd == "DEVICE" { return DeviceRelay.command(w) }   // waits on the device: off the main thread
        if cmd == "TYPE", w.count >= 2 {
            let field = w[0], text = w[1], cps = Double(w.count > 2 ? w[2] : "") ?? 12
            if field.lowercased() != "alert" && !settable.contains(where: { $0.lowercased() == field.lowercased() }) {
                return "ERR field is one of: \(settable.joined(separator: ", ")), alert"
            }
            var s = ""
            for ch in text {
                s.append(ch)
                let typed = s
                let r = onMain { setField(field, typed) }
                if r.hasPrefix("ERR") { return r }
                if cps > 0 { usleep(useconds_t(1e6 / cps)) }
            }
            return "OK"
        }
        let args = w
        return onMain { handle(cmd, args) }
    }

    // MARK: dispatch

    static func handle(_ cmd: String, _ w: [String]) -> String {
        let m = AppModel.shared
        func arg(_ i: Int) -> String { i < w.count ? w[i] : "" }
        func later(_ f: @escaping @MainActor () -> Void) -> String { mainSoon(f); return "OK" }
        switch cmd {
        case "HELP": return help
        case "PING":
            return "PONG " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        case "STATE": return json(state())
        case "WINDOWS": return json(windows())
        case "ALERT":
            guard let a = currentAlertWindow() else { return "ERR no alert" }
            return json(describeAlert(a))

        // the menu-bar panel
        case "PANEL":
            switch arg(0).lowercased() {
            case "close": if let p = panelWindow(), p.isVisible { toggleStatusItem() }; return "OK"
            case "toggle": toggleStatusItem(); return "OK"
            default: if panelWindow()?.isVisible != true { toggleStatusItem() }; return "OK"
            }
        case "SECTION":   // SECTION accounts|install|settings open|close
            let open = arg(1).lowercased() != "close"
            switch arg(0).lowercased() {
            case "accounts": m.accountsExpanded = open
            case "install": m.installExpanded = open
            case "settings": m.settingsExpanded = open
            default: return "ERR section is accounts|install|settings"
            }
            return "OK"
        case "EXPAND", "COLLAPSE":   // EXPAND account <appleID> | app <appleID/origBundleID> | apps | accounts
            let open = cmd == "EXPAND"
            switch arg(0).lowercased() {
            case "account": m.collapsedAccounts = open ? m.collapsedAccounts.subtracting([arg(1)]) : m.collapsedAccounts.union([arg(1)])
            case "app": m.collapsedApps = open ? m.collapsedApps.subtracting([arg(1)]) : m.collapsedApps.union([arg(1)])
            case "apps": m.collapsedApps = open ? [] : Set(m.tracked.map { "\($0.appleID)/\($0.origBundleID)" })
            case "accounts": m.collapsedAccounts = open ? [] : Set(m.accounts.map { $0.appleID })
            default: return "ERR EXPAND account <appleID> | app <appleID/origBundleID> | apps | accounts"
            }
            m.didSeedCollapse = true
            return "OK"

        // every button and prompt the panel offers
        case "DO":
            let what = arg(0).lowercased()
            switch what {
            case "add-account": m.addingAccount = true; return "OK"
            case "cancel-add-account": m.addingAccount = false; return "OK"
            case "pick-ipa": return later { m.pickIPA() }
            case "pick-json": return later { m.pickJSON() }
            case "github-prompt": return later { m.promptGitHubInstall() }
            case "altstore-repo-prompt": return later { m.promptAltStore() }
            case "search-github":
                m.showGitHubSearchWindow()
                if !arg(1).isEmpty { m.githubQuery = arg(1); m.searchGitHub() }
                return "OK"
            case "close-search-github": m.closeGitHubSearch(); return "OK"
            case "github-user": m.installFromGitHubUser(arg(1)); return "OK"
            case "search-altstore":
                m.showAltStoreSearchWindow()
                if !arg(1).isEmpty { m.altStoreQuery = arg(1); m.filterAltStore() }
                return "OK"
            case "close-search-altstore": m.closeAltStoreSearch(); return "OK"
            case "load-source": m.sourceURL = arg(1); m.loadSource(); return "OK"
            case "add-source": return later { m.addAltStoreSource(arg(1)) }   // Search AltStore ▸ Sources ▸ Add (blocked sources get the refusal alert)
            case "install-github": return later { m.installFromGitHub(arg(1)) }
            case "install-source":   // by name, from the panel's source list or the AltStore catalog
                guard let app = (m.sourceApps + m.altStoreAllApps).first(where: { $0.name.lowercased() == arg(1).lowercased() })
                else { return "ERR no source app named \(arg(1))" }
                return later { m.startInstall(.source(app)) }
            case "open-ipa": return later { m.openIPA(arg(1)) }
            case "url":
                guard let u = URL(string: arg(1)) else { return "ERR bad url" }
                return later { m.handleURLScheme(u) }
            case "refresh", "refresh-everywhere":   // refresh <origBundleID> [udid] [appleID]
                guard let t = m.tracked.first(where: { $0.origBundleID == arg(1) && (arg(2).isEmpty || $0.udid == arg(2))
                                                       && (arg(3).isEmpty || $0.appleID == arg(3)) })
                else { return "ERR no tracked app \(arg(1)) \(arg(2))" }
                return later { what == "refresh" ? m.refreshApp(t) : m.refreshAppEverywhere(t) }
            case "refresh-all": m.refreshAllNow(); return "OK"
            case "check-updates": m.checkGitHubUpdatesNow(); return "OK"
            case "self-update-check": return later { Task { await UpdateChecker.shared.check(userInitiated: true) } }
            case "token-prompt": return later { m.promptGitHubToken() }
            case "anisette-prompt": return later { m.promptAnisetteServer() }
            case "debug-log": DebugWindow.show(); return "OK"
            case "devmode-help":   // devmode-help <device name> [manual|rebooting]
                m.showDevModeHelp(deviceName: arg(1), mode: arg(2).lowercased() == "rebooting" ? .rebooting : .manual)
                return "OK"
            case "trust-hint":   // shows the one-time alert even if already shown
                UserDefaults.standard.removeObject(forKey: "sidestep.trusted.\(arg(1))")
                return later { m.maybeShowTrustHint(appleID: arg(1)) }
            default: return "ERR unknown DO \(what) — see HELP"
            }

        // fields: SET sets at once; TYPE (handled in dispatch) types letter by letter, for video
        case "SET", "TYPE": return setField(arg(0), arg(1))
        case "CLICK":   // CLICK <button title> — a button in an alert or AppKit window
            guard let b = findButton(arg(0)) else { return "ERR no button \"\(arg(0))\"" }
            return later { b.performClick(nil) }
        case "CLOSE":   // CLOSE <window title substring>
            guard let win = findWindow(arg(0)) else { return "ERR no window \"\(arg(0))\"" }
            win.close(); return "OK"

        case "SNAP":   // SNAP panel|alert|<title substring>|<window number> [path] [scale]
            guard let win = findWindow(arg(0)) else { return "ERR no window \"\(arg(0))\"" }
            let scale = Double(arg(2)) ?? win.backingScaleFactor
            guard let png = snapshot(win, scale: scale) else { return "ERR snapshot failed" }
            let path = arg(1).isEmpty ? defaultSnapPath() : (arg(1) as NSString).expandingTildeInPath
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return "ERR \(error.localizedDescription)" }
            return json(["path": path, "window": win.windowNumber, "title": win.title,
                         "width": win.frame.width, "height": win.frame.height,
                         "scale": scale])

        case "DEMO":   // DEMO alias "<real text>" "<shown instead>" | DEMO clear | DEMO list
            switch arg(0).lowercased() {
            case "alias": guard !arg(1).isEmpty else { return "ERR DEMO alias <from> <to>" }
                Demo.aliases[arg(1)] = arg(2); m.objectWillChange.send(); return "OK"
            case "clear": Demo.aliases = [:]; m.objectWillChange.send(); return "OK"
            default: return json(Demo.aliases)
            }
        default: return "ERR unknown \(cmd) — see HELP"
        }
    }

    static let help = """
    PING · STATE · WINDOWS · ALERT · PANEL [open|close|toggle] · SECTION accounts|install|settings open|close · \
    EXPAND|COLLAPSE account <appleID> | app <appleID/origBundleID> | apps | accounts · \
    DO add-account|cancel-add-account|pick-ipa|pick-json|github-prompt|altstore-repo-prompt|search-github [q]|\
    close-search-github|github-user <u>|search-altstore [q]|close-search-altstore|load-source <url>|add-source <url>|install-github <repo>|\
    install-source <name>|open-ipa <path>|url <sidestep://…>|refresh <origBundleID> [udid] [appleID]|refresh-everywhere <origBundleID>|\
    refresh-all|check-updates|self-update-check|token-prompt|anisette-prompt|debug-log|devmode-help <device> [manual|rebooting]|\
    trust-hint <appleID> · SET|TYPE <field> <text> [chars/s] (fields: githubQuery altStoreQuery appleID password code sourceURL alert) · \
    CLICK <button title> · CLOSE <window title> · SNAP panel|alert|<title>|<window#> [path] [scale] · DEMO alias <from> <to> | clear | list · \
    DEVICES · DEVICE <udid|bundle|name|any> <beacon command…> (PANEL [close], MORE, UI, PICK <t>, TYPE <t>, SET <t>, ROW <t>, DONE, \
    UPDATE, BEACON, STATE, PING, ALIAS <from>|<to>, ALIAS clear, SNAP [path])
    """

    // MARK: fields

    nonisolated static let settable = ["githubQuery", "altStoreQuery", "appleID", "password", "code", "sourceURL"]
    static func setField(_ f: String, _ v: String) -> String {
        let m = AppModel.shared
        switch f.lowercased() {
        case "githubquery": m.githubQuery = v
        case "altstorequery": m.altStoreQuery = v; m.filterAltStore()
        case "appleid": m.appleID = v
        case "password": m.password = v
        case "code": m.code = v
        case "sourceurl": m.sourceURL = v
        case "alert":
            guard let a = currentAlertWindow(), let tf = textFields(in: a.contentView).first else { return "ERR no alert text field" }
            tf.stringValue = v
        default: return "ERR field is one of: \(settable.joined(separator: ", ")), alert"
        }
        return "OK"
    }

    // MARK: windows

    /// The menu-bar status item's button lives in an NSStatusBarWindow; clicking it opens
    /// or closes the MenuBarExtra panel (there's no public API to do this directly).
    static func toggleStatusItem() {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBarWindow") {
            if let b = allSubviews(w.contentView).compactMap({ $0 as? NSButton }).first { b.performClick(nil); return }
        }
    }
    /// The MenuBarExtra panel: the window hosting RootPanel (no title, not the status bar).
    static func panelWindow() -> NSWindow? {
        NSApp.windows.first { w in
            let cls = String(describing: type(of: w))
            return !cls.contains("StatusBarWindow") && (cls.contains("MenuBarExtra") || (w.title.isEmpty && w is NSPanel && abs(w.frame.width - 470) < 2))
        }
    }
    static func currentAlertWindow() -> NSWindow? {
        if let w = NSApp.modalWindow { return w }
        return NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Alert") }
    }
    static func findWindow(_ key: String) -> NSWindow? {
        switch key.lowercased() {
        case "panel": return panelWindow()
        case "alert", "modal": return currentAlertWindow()
        case "": return NSApp.keyWindow
        default:
            if let n = Int(key) { return NSApp.windows.first { $0.windowNumber == n } }
            return NSApp.windows.first { $0.isVisible && $0.title.localizedCaseInsensitiveContains(key) }
        }
    }
    static func allSubviews(_ v: NSView?) -> [NSView] {
        guard let v else { return [] }
        return [v] + v.subviews.flatMap { allSubviews($0) }
    }
    static func textFields(in v: NSView?) -> [NSTextField] {
        allSubviews(v).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
    }
    /// A button by title: the current alert first, then the key window, then any window.
    static func findButton(_ title: String) -> NSButton? {
        let order = [currentAlertWindow(), NSApp.keyWindow].compactMap { $0 } + NSApp.windows.filter(\.isVisible)
        for w in order {
            for case let b as NSButton in allSubviews(w.contentView) where b.isEnabled &&
                b.title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title) == .orderedSame {
                return b
            }
        }
        return nil
    }
    static func describeAlert(_ w: NSWindow) -> [String: Any] {
        let views = allSubviews(w.contentView)
        let texts = views.compactMap { $0 as? NSTextField }.filter { !$0.isEditable }.map(\.stringValue).filter { !$0.isEmpty }
        return ["window": w.windowNumber,
                "texts": texts,
                "buttons": views.compactMap { ($0 as? NSButton)?.title }.filter { !$0.isEmpty },
                "fields": textFields(in: w.contentView).map(\.stringValue)]
    }
    static func windows() -> [[String: Any]] {
        NSApp.windows.filter(\.isVisible).map { w in
            ["number": w.windowNumber, "title": w.title, "class": String(describing: type(of: w)),
             "x": w.frame.minX, "y": w.frame.minY, "width": w.frame.width, "height": w.frame.height,
             "key": w.isKeyWindow, "modal": w == NSApp.modalWindow, "panel": w == panelWindow()]
        }
    }

    // MARK: state

    static func state() -> [String: Any] {
        let m = AppModel.shared
        let df = ISO8601DateFormatter()
        return [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "installing": m.installing, "status": m.status,
            "progressWindow": ["title": m.ipTitle, "status": m.ipStatus, "done": m.ipDone, "ok": m.ipOK,
                               "result": m.ipResult, "progress": m.ipProgress ?? -1, "detail": m.ipDetail],
            "panel": ["open": panelWindow()?.isVisible == true, "accounts": m.accountsExpanded,
                      "install": m.installExpanded, "settings": m.settingsExpanded, "addingAccount": m.addingAccount,
                      "collapsedApps": Array(m.collapsedApps), "collapsedAccounts": Array(m.collapsedAccounts)],
            "accounts": m.accounts.map { ["appleID": $0.appleID, "name": $0.displayName, "team": $0.teamName,
                                          "teams": $0.teams.map(\.label)] },
            "apps": m.tracked.map { t -> [String: Any] in
                var d: [String: Any] = ["name": t.name, "origBundleID": t.origBundleID, "appleID": t.appleID,
                                        "udid": t.udid, "device": t.deviceName, "version": t.version,
                                        "githubRepo": t.githubRepo, "autoUpdates": t.autoUpdates]
                if let li = t.lastInstalled {
                    d["expires"] = df.string(from: Date(timeIntervalSince1970: li + Double(t.validityDays) * 86400))
                }
                return d
            },
            "sourceApps": m.sourceApps.map(\.name),
            "github": ["query": m.githubQuery, "searching": m.githubSearching, "note": m.githubSearchNote,
                       "results": m.githubResults.map(\.repo)],
            "altstore": ["query": m.altStoreQuery, "loading": m.altStoreLoading, "count": m.altStoreResults.count,
                         "first": m.altStoreResults.prefix(10).map(\.name)],
            "windows": windows(),
        ]
    }

    // MARK: snapshots

    /// PNG of one of SideStep's own windows, drawn by the app itself — needs no Screen
    /// Recording permission and doesn't disturb the screen. The frame view is drawn so the
    /// title bar is included for titled windows.
    static func snapshot(_ w: NSWindow, scale: Double) -> Data? {
        guard let v = w.contentView?.superview ?? w.contentView else { return nil }
        let r = v.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(r.width * scale), pixelsHigh: Int(r.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = r.size   // points → pixels at `scale`, so a 1x screen still gives a crisp 2x image
        v.cacheDisplay(in: r, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    nonisolated static func defaultSnapPath() -> String {
        try? FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return snapDir.appendingPathComponent("snap-\(f.string(from: Date())).png").path
    }

    // MARK: helpers

    /// Split on spaces, keeping "double-quoted phrases" together.
    nonisolated static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, has = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); has = true }
            else if ch == " " && !quoted { if has || !cur.isEmpty { out.append(cur) }; cur = ""; has = false }
            else { cur.append(ch) }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }
    nonisolated static func json(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "ERR json" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Display-only name substitution for screenshots and videos (DEMO alias), so real Apple
/// IDs and device names never appear. Empty unless set over the debug channel.
@MainActor enum Demo {
    static var aliases: [String: String] = [:]
    static func s(_ text: String) -> String {
        guard !aliases.isEmpty else { return text }
        var t = text
        for (from, to) in aliases.sorted(by: { $0.key.count > $1.key.count }) { t = t.replacingOccurrences(of: from, with: to) }
        return t
    }
}

/// The Mac end of the beacon's control channel. An app installed while a debug token is
/// configured carries that token (BeaconInjector) and dials this Mac on TCP 51236 once it
/// has Local Network access, sending "HELLO <token> <udid> <bundle> <version>". We keep
/// each such connection and forward `DEVICE <match> <command>` lines to it, one at a time.
/// (Provision --beacon-serve uses the same port, so it can't run while SideStep does.)
enum DeviceRelay {
    static let port: UInt16 = 51236
    nonisolated(unsafe) private static var listener: NWListener?
    nonisolated(unsafe) private static var token = ""
    private static let lock = NSLock()
    nonisolated(unsafe) private static var devices: [String: Device] = [:]   // "udid bundle" → connection

    final class Device: @unchecked Sendable {
        let c: NWConnection
        var udid = "", bundle = "", version = ""
        var buf = Data()
        var replies: [String] = []
        let ready = DispatchSemaphore(value: 0)      // one per reply line received
        let oneAtATime = NSLock()                     // a device answers commands in order
        init(_ c: NWConnection) { self.c = c }
    }

    static func start(token t: String) {
        guard listener == nil else { return }
        token = t
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { c in accept(c) }
            l.stateUpdateHandler = { st in dlog("device relay: \(st)") }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
            dlog("device relay: waiting for beacons on tcp/\(port)")
        } catch { dlog("device relay: couldn't listen on \(port): \(error)") }
    }

    private static func accept(_ c: NWConnection) {
        let d = Device(c)
        c.start(queue: .global(qos: .userInitiated))
        read(d)
    }
    private static func read(_ d: Device) {
        d.c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
            if let data { d.buf.append(data) }
            while let nl = d.buf.firstIndex(of: 0x0A) {
                let line = String(decoding: d.buf[d.buf.startIndex..<nl], as: UTF8.self)
                d.buf.removeSubrange(d.buf.startIndex...nl)
                if d.udid.isEmpty {   // first line must be the HELLO
                    let p = line.split(separator: " ").map(String.init)
                    guard p.count >= 4, p[0] == "HELLO", p[1] == token else { d.c.cancel(); return }
                    d.udid = p[2]; d.bundle = p[3]; d.version = p.count > 4 ? p[4] : ""
                    lock.lock(); devices["\(d.udid) \(d.bundle)"] = d; lock.unlock()
                    dlog("device relay: \(d.bundle) on \(d.udid) connected")
                } else {
                    lock.lock(); d.replies.append(line); lock.unlock(); d.ready.signal()
                }
            }
            if done || err != nil {
                lock.lock(); if devices["\(d.udid) \(d.bundle)"] === d { devices["\(d.udid) \(d.bundle)"] = nil }; lock.unlock()
                d.c.cancel(); d.ready.signal()
                dlog("device relay: \(d.bundle) on \(d.udid) gone")
            } else { read(d) }
        }
    }

    static func list() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return devices.values.map { ["udid": $0.udid, "bundle": $0.bundle, "version": $0.version,
                                     "device": DeviceIPCache.name(for: $0.udid) ?? ""] }
    }

    /// DEVICE <match> <command…>; match is "any", or part of a udid, bundle id or device name.
    static func command(_ w: [String]) -> String {
        guard w.count >= 2 else { return "ERR DEVICE <udid|bundle|name|any> <command…>" }
        let match = w[0].lowercased()
        lock.lock()
        let all = devices.values.sorted { $0.bundle < $1.bundle }
        let d = all.first { match == "any" || $0.udid.lowercased().contains(match) || $0.bundle.lowercased().contains(match)
                            || (DeviceIPCache.name(for: $0.udid) ?? "").lowercased().contains(match) }
        lock.unlock()
        guard let d else { return "ERR no connected beacon matches \"\(w[0])\" (DEVICES lists them)" }
        var args = Array(w.dropFirst())
        let isSnap = args[0].uppercased() == "SNAP"
        let path = isSnap && args.count > 1 ? (args[1] as NSString).expandingTildeInPath : nil
        if isSnap { args = ["SNAP"] }

        d.oneAtATime.lock(); defer { d.oneAtATime.unlock() }
        let out = "\(token) \(args.joined(separator: " "))\n"
        d.c.send(content: out.data(using: .utf8), completion: .contentProcessed { _ in })
        let wait: Double = isSnap ? 60 : (args[0].uppercased() == "TYPE" ? 30 + Double(args.count) * 3 : 30)
        guard d.ready.wait(timeout: .now() + wait) == .success else { return "ERR device didn't answer in \(Int(wait))s" }
        lock.lock(); let reply = d.replies.isEmpty ? "ERR device disconnected" : d.replies.removeFirst(); lock.unlock()
        guard isSnap, reply.hasPrefix("PNG ") else { return reply }
        guard let png = Data(base64Encoded: String(reply.dropFirst(4))) else { return "ERR bad PNG from device" }
        let file = path ?? DebugControl.defaultSnapPath().replacingOccurrences(of: "snap-", with: "device-")
        do { try png.write(to: URL(fileURLWithPath: file)) } catch { return "ERR \(error.localizedDescription)" }
        let img = NSImage(data: png)?.representations.first
        return DebugControl.json(["path": file, "width": img?.pixelsWide ?? 0, "height": img?.pixelsHigh ?? 0,
                                  "udid": d.udid, "bundle": d.bundle])
    }
}
