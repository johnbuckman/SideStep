// InstallServer — the Mac half of the on-device "Install more apps…" browser.
// A tiny line-based TCP service (port 51235) the injected beacon UI talks to over
// Wi-Fi to (a) list apps installed on the user's OTHER devices, (b) search the
// AltStore catalog, and (c) install a chosen app onto the requesting device.
//
// Protocol — the device sends ONE request line (\n-terminated):
//   LIST udid=<udid>
//   SEARCH udid=<udid> q=<query>
//   INSTALL udid=<udid> kind=other  bundle=<origBundleID>
//   INSTALL udid=<udid> kind=source bundle=<id> url=<ipaURL> name=<name>
//   INSTALL udid=<udid> kind=github repo=<owner/name>
// Mac replies:
//   LIST/SEARCH → one JSON line, then close.
//   INSTALL     → streamed "STATUS …" / "PROGRESS pct eta" lines, then
//                 "DONE ok" or "DONE fail <message>", then close.
import Foundation
import AltSign

public final class InstallServer: NSObject {
    public static let shared = InstallServer()
    public static let port: UInt16 = 51235

    private let q = DispatchQueue(label: "com.decent.sidestep.installserver")
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1
    private var log: (String) -> Void = { _ in }

    public func start(log: @escaping (String) -> Void) {
        q.async {
            guard self.source == nil else { return }
            self.log = log
            guard self.bind() else { log("install server: bind FAILED"); return }
            let src = DispatchSource.makeReadSource(fileDescriptor: self.fd, queue: self.q)
            src.setEventHandler { [weak self] in self?.accept() }
            src.resume()
            self.source = src
            log("install server up on tcp/\(InstallServer.port)")
        }
    }

    private func bind() -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        if s < 0 { return false }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = InstallServer.port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let br = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if br != 0 { close(s); return false }
        if listen(s, 8) != 0 { close(s); return false }
        self.fd = s
        return true
    }

    private func accept() {
        var peer = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let c = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(self.fd, $0, &len) } }
        if c < 0 { return }
        var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &peer.sin_addr, &ipbuf, socklen_t(INET_ADDRSTRLEN))
        let peerIP = String(cString: ipbuf)
        // Handle off the accept queue so a long install doesn't block new connections.
        DispatchQueue.global(qos: .userInitiated).async { self.handle(conn: c, peerIP: peerIP) }
    }

    // MARK: line I/O
    private func readLine(_ c: Int32, max: Int = 4096) -> String {
        var bytes = [UInt8](); var b: UInt8 = 0
        while bytes.count < max {
            let n = recv(c, &b, 1, 0)
            if n <= 0 { break }
            if b == 0x0A { break }
            bytes.append(b)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
    private func send(_ c: Int32, _ line: String) {
        let data = Array((line + "\n").utf8)
        data.withUnsafeBytes { _ = Darwin.send(c, $0.baseAddress, data.count, 0) }
    }
    private func field(_ s: String, _ k: String) -> String? {
        // key=value where value runs to the next " key2=" or end (so q= / name= can hold spaces)
        guard let r = s.range(of: "\(k)=") else { return nil }
        let rest = s[r.upperBound...]
        // stop at the next " word=" token
        if let stop = rest.range(of: #" [a-z]+="#, options: .regularExpression) {
            return String(rest[..<stop.lowerBound])
        }
        return String(rest)
    }

    // MARK: request handling
    private func handle(conn c: Int32, peerIP: String) {
        defer { close(c) }
        let req = readLine(c)
        self.log("install server: \(peerIP) → \(req.prefix(120))")
        if req.hasPrefix("LIST") {
            send(c, listJSON(excludeUDID: field(req, "udid") ?? ""))
        } else if req.hasPrefix("SEARCH") {
            let sem = DispatchSemaphore(value: 0)
            Task { let j = await self.searchJSON(field(req, "q") ?? ""); self.send(c, j); sem.signal() }
            sem.wait()
        } else if req.hasPrefix("GHUSER") {
            let sem = DispatchSemaphore(value: 0)
            Task { let j = await self.githubUserJSON(field(req, "user") ?? ""); self.send(c, j); sem.signal() }
            sem.wait()
        } else if req.hasPrefix("INSTALL") {
            let sem = DispatchSemaphore(value: 0)
            Task { await self.doInstall(req, peerIP: peerIP, conn: c); sem.signal() }
            sem.wait()
        } else {
            send(c, "ERR unknown request")
        }
    }

    // MARK: LIST — apps installed on the user's OTHER devices (deduped by app)
    private func listJSON(excludeUDID udid: String) -> String {
        var seen = Set<String>(); var out: [[String: Any]] = []
        for t in Tracked.all() where t.udid.caseInsensitiveCompare(udid) != .orderedSame {
            if seen.contains(t.origBundleID) { continue }
            seen.insert(t.origBundleID)
            out.append([
                "name": t.name, "bundle": t.origBundleID,
                "device": t.deviceName.isEmpty ? DeviceIPCache.name(for: t.udid) ?? "" : t.deviceName,
                "version": t.version,
                "via": t.githubRepo.isEmpty ? (t.origin.hasPrefix("http") ? "AltStore" : "File") : "GitHub",
            ])
        }
        return json(["apps": out])
    }

    // MARK: SEARCH — the AltStore catalog
    private func searchJSON(_ query: String) async -> String {
        let all = await AltStoreCatalog.allApps()
        let hits = AltStoreCatalog.search(query, in: all).prefix(60)
        let out: [[String: Any]] = hits.map { a in
            ["name": a.name, "bundle": a.bundleIdentifier, "url": a.downloadURL,
             "version": a.version ?? "", "source": a.sourceName, "developer": a.developerName ?? ""]
        }
        return json(["apps": out])
    }

    // MARK: GHUSER — a GitHub user's public repos that publish an .ipa
    private func githubUserJSON(_ user: String) async -> String {
        let hits = await GitHub.userReposWithIPA(user)
        let out: [[String: Any]] = hits.map { h in
            let short = h.repo.split(separator: "/").last.map(String.init) ?? h.repo
            return ["name": short, "repo": h.repo, "version": h.ipa?.tag ?? "", "source": h.description]
        }
        // If nothing came back because GitHub's unauthenticated limit is spent and no
        // token is saved, tell the device so — the token is added on the Mac, so the
        // device just points the user there rather than showing a bare "none found".
        if out.isEmpty, !GitHub.hasToken, let rem = await GitHub.coreRemaining(), rem < 3 {
            return json(["apps": out, "note": "GitHub's hourly limit is used up. On your Mac, open SideStep ▸ Settings ▸ “Add a GitHub token” to raise it, then try again."])
        }
        return json(["apps": out])
    }

    // MARK: INSTALL — sign + install the chosen app onto the requesting device
    private func doInstall(_ req: String, peerIP: String, conn c: Int32) async {
        guard let udid = field(req, "udid"), let kind = field(req, "kind") else { send(c, "DONE fail bad request"); return }
        // The connecting device's IP is where we push over Wi-Fi.
        DeviceIPCache.remember(udid, ip: peerIP)

        // status streamer: map install log lines to STATUS / PROGRESS for the device.
        final class UpState { var start = Date(); var started = false }
        let up = UpState()
        let stream: (String) -> Void = { [weak self] msg in
            guard let self else { return }
            self.log(msg)
            if msg.hasPrefix("PROGRESS ") {
                let p = msg.split(separator: " ")
                if p.count >= 3, let sent = Double(p[1]), let total = Double(p[2]), total > 0 {
                    if !up.started { up.start = Date(); up.started = true }
                    let pct = Int(min(100, sent / total * 100))
                    let el = Date().timeIntervalSince(up.start)
                    let eta = (sent > 1e5 && el > 1) ? Int((total - sent) / (sent / el)) : -1
                    self.send(c, "PROGRESS \(pct) \(eta)")
                }
                return
            }
            if let f = InstallServer.friendly(msg) { self.send(c, "STATUS \(f)") }
        }

        // Build the install action + the bundle id used to prefer an Apple ID.
        var bundle = field(req, "bundle") ?? ""
        let action: (ALTAccount, ALTAppleAPISession) async throws -> String
        switch kind {
        case "other":
            guard let t = Tracked.all().first(where: { $0.origBundleID == bundle }) else { send(c, "DONE fail app not found"); return }
            action = { acc, ses in try await Sideloader.installTracked(t, onUDID: udid, account: acc, session: ses, log: stream) }
        case "source":
            let app = SourceApp(name: field(req, "name") ?? bundle, bundleIdentifier: bundle,
                                downloadURL: field(req, "url") ?? "", version: nil, localizedDescription: nil,
                                iconURL: nil, developerName: nil, sourceName: "")
            action = { acc, ses in try await Sideloader.installSourceApp(account: acc, session: ses, app: app, iPadUDID: udid, log: stream) }
        case "github":
            let repo = field(req, "repo") ?? ""
            bundle = ""   // resolved from the repo; no prior-bundle match
            action = { acc, ses in try await Sideloader.installFromGitHub(account: acc, session: ses, repo: repo, iPadUDID: udid, log: stream) }
        default:
            send(c, "DONE fail unknown kind"); return
        }

        // Prefer an Apple ID already used for this app (reuses its slot); then the rest.
        // Auto-advance past accounts that have hit Apple's device limit.
        let prior = Set(Tracked.all().filter { !bundle.isEmpty && $0.origBundleID == bundle }.map { $0.appleID })
        let candidates = AccountStore.records().map { $0.appleID }
            .sorted { (prior.contains($0) ? 0 : 1) < (prior.contains($1) ? 0 : 1) }
        if candidates.isEmpty { send(c, "DONE fail no Apple ID set up in SideStep"); return }

        var lastErr = "couldn't install"
        for aid in candidates {
            guard let (acc, ses) = await Sideloader.ensureSession(aid, log: stream) else { lastErr = "sign-in failed for \(aid)"; continue }
            send(c, "STATUS Signing with \(aid)…")
            do {
                _ = try await action(acc, ses)
                send(c, "PROGRESS 100 0")
                // Identify the Mac + signing Apple ID so the device popup can show them.
                send(c, "HOST \(Sideloader.computerName())")
                send(c, "SIGNER \(aid)")
                send(c, "DONE ok")
                return
            } catch let e as SideErr {
                if case .deviceLimit = e { lastErr = "\(aid) can’t register more devices"; send(c, "STATUS \(aid) is full — trying another Apple ID…"); continue }
                lastErr = e.errorDescription ?? "install failed"; break
            } catch {
                lastErr = error.localizedDescription; break
            }
        }
        send(c, "DONE fail \(lastErr)")
    }

    private static func friendly(_ msg: String) -> String? {
        if msg.contains("Registering") || msg.contains("Team:")        { return "Preparing…" }
        if msg.contains("App ID") || msg.contains("profile")           { return "Getting a signing profile…" }
        if msg.contains("Signing")                                      { return "Signing the app…" }
        if msg.contains("Downloading")                                  { return "Downloading the app…" }
        if msg.contains("Installing by direct IP") || msg.contains("uploaded") { return "Sending it to your device…" }
        if msg.contains("INSTALL OK") || msg.contains("Installed ") || msg.contains("DIRECT-IP INSTALL OK") { return "Almost done…" }
        return nil
    }

    private func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{\"apps\":[]}" }
        return s
    }
}
