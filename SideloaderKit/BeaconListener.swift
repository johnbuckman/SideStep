// BeaconListener — the Mac half of the wireless self-update loop, native to
// SideStep (replaces the external Python listener). Listens for UDP beacons
// from instrumented apps, learns the device IP from the packet source, and
// re-signs + pushes the matching tracked app back over Wi-Fi. Also advertises
// the `_sidestep._udp` Bonjour service so beacons can find the Mac by name.
import Foundation

public final class BeaconListener: NSObject {
    public static let shared = BeaconListener()
    public static let port: UInt16 = 51234

    private let q = DispatchQueue(label: "com.decent.sidestep.beacon")
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1
    private var advertiser: NetService?
    // Updates in flight, keyed by "udid|bundleid" → last time that install showed activity.
    // Per (device, app), NOT one Mac-wide busy flag: until 0.2.74 a single `busy` bool made every
    // other app/device that beaconed during an update (incl. a minutes-long cascade) get "Mac is
    // busy with another update" and give up. Now different keys run concurrently — installs to
    // the same device still queue in InstallGate.devices — and only a repeat beacon for the SAME
    // key is collapsed ("Still updating"). All access on `q`.
    private var inFlight: [String: Date] = [:]
    // Slightly above the 360s per-app withTimeout so a normal (even slow) install never trips it,
    // but a permanently-wedged install (uncancellable Apple-API/URLSession hang that withTimeout
    // can't actually abandon) can't pin its key in `inFlight` forever.
    private static let busyStaleAfter: TimeInterval = 420
    private var lastPush: [String: Date] = [:]   // per (udid|bundleid), debounce the packet burst
    private var log: (String) -> Void = { _ in }

    /// Fired after a beacon-driven (re)install updates the tracked store, so the Mac UI can reload
    /// its in-memory app list and show the just-installed version. Without this, a wireless
    /// self-update lands on the device and `Tracked.upsert` records the new version on disk, but
    /// the running app's cached list keeps showing the old version until relaunch.
    public var onInstalled: (@Sendable () -> Void)?

    public func start(log: @escaping (String) -> Void) {
        q.async {
            guard self.source == nil else { return }
            self.log = log
            CrashLog.log("BeaconListener: binding udp/\(BeaconListener.port)…")
            guard self.bind() else { CrashLog.log("BeaconListener: bind FAILED"); return }
            CrashLog.log("BeaconListener: bound OK; advertising _sidestep._udp…")
            self.advertise()
            CrashLog.log("BeaconListener: advertise dispatched OK")
            log("beacon listener up on udp/\(BeaconListener.port)")
        }
    }

    // MARK: receive

    private func bind() -> Bool {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        if s < 0 { log("beacon: socket() failed"); return false }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = BeaconListener.port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let br = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if br != 0 { log("beacon: bind :\(BeaconListener.port) failed (already in use?)"); close(s); return false }
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: q)
        src.setEventHandler { [weak self] in self?.receive() }
        src.setCancelHandler { close(s) }
        src.resume()
        source = src
        return true
    }

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in(); var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { fp in
            recvfrom(fd, &buf, buf.count, 0, fp, &fl)
        } }
        guard n > 0 else { return }
        let text = String(decoding: buf[0..<n], as: UTF8.self)
        handle(text, from: from)
    }

    /// Send a raw line back to the device's beacon socket.
    private func sendRaw(_ line: String, to dest: sockaddr_in) {
        let s = socket(AF_INET, SOCK_DGRAM, 0); if s < 0 { return }; defer { close(s) }
        var d = dest
        let msg = Array(line.utf8)
        _ = withUnsafePointer(to: &d) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { dp in
            msg.withUnsafeBytes { sendto(s, $0.baseAddress, msg.count, 0, dp, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } }
    }
    private func sendStatus(_ text: String, to dest: sockaddr_in) { sendRaw("STATUS \(text)\n", to: dest) }
    private func sendProgress(pct: Int, eta: Int, to dest: sockaddr_in) { sendRaw("PROGRESS \(pct) \(eta)\n", to: dest) }

    static let stepTotal = 6
    /// Map an internal install log line to a numbered step (1…6) + a device-facing label,
    /// or nil if the line doesn't mark a new phase. The device shows "n/6 Label" as the
    /// headline status; the caller only advances (never goes backwards).
    private static func step(for msg: String) -> (Int, String)? {
        let m = msg.lowercased()
        if m.contains("sign in") || m.contains("apple id") || m.contains("signing in")     { return (1, "Signing in to your Apple ID") }
        if m.contains("download") || m.hasPrefix("github:") || m.contains("github —")       { return (2, "Downloading the latest build") }
        if m.contains("app id") || m.contains("profile") || m.contains("registering")
            || m.contains("preparing") || m.contains("team:")                               { return (3, "Preparing the signing profile") }
        if m.contains("signing") || m.contains("extension:")                                { return (4, "Signing the app") }
        if m.contains("uploading") || m.contains("sending") || m.contains("direct ip")      { return (5, "Sending it to your device") }
        if m.contains("installing on") || m.contains("install ok") || m.contains("installed ") { return (6, "Installing on your device") }
        return nil
    }
    /// A compact, device-facing "Now:" detail line from a raw log line (so a hang is
    /// visible at fine grain). Trimmed + length-capped for the small on-device label.
    private static func nowDetail(_ msg: String) -> String {
        let one = msg.split(whereSeparator: { $0 == "\n" }).first.map(String.init) ?? msg
        let clean = one.replacingOccurrences(of: ">>> ", with: "").trimmingCharacters(in: .whitespaces)
        return clean.count > 110 ? String(clean.prefix(110)) + "…" : clean
    }

    private func field(_ s: String, _ k: String) -> String? {
        for tok in s.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let p = tok.split(separator: "=", maxSplits: 1)
            if p.count == 2 && p[0] == Substring(k) { return String(p[1]) }
        }
        return nil
    }

    private func handle(_ text: String, from: sockaddr_in) {
        // Same-account-on-two-Macs guard: answer a claim if we hold that Apple ID.
        if text.hasPrefix("SIDESTEP-CLAIM ") {
            let parts = text.dropFirst("SIDESTEP-CLAIM ".count).split(whereSeparator: { $0 == " " || $0 == "\n" })
            if parts.count >= 2, LANLock.shouldAnswer(instanceID: String(parts[0]), hash: String(parts[1])) {
                sendRaw("SIDESTEP-OWNED \(LANLock.hostName())\n", to: from)
            }
            return
        }
        var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var f = from
        inet_ntop(AF_INET, &f.sin_addr, &ipbuf, socklen_t(INET_ADDRSTRLEN))
        let ip = String(cString: ipbuf)
        guard text.hasPrefix("BEACON"), field(text, "unlocked") == "1",
              let udid = field(text, "udid"), let bundle = field(text, "bundleid") else { return }
        DeviceIPCache.remember(udid, ip: ip)   // so a later manual Refresh can reach it by IP
        if let nm = field(text, "name"), !nm.isEmpty {   // beacon sends spaces as underscores
            DeviceIPCache.rememberName(udid, name: nm.replacingOccurrences(of: "_", with: " "))
        }
        let key = "\(udid)|\(bundle)"
        let now = Date()
        if let last = inFlight[key] {
            // Self-heal: `withTimeout(360)` can't truly abandon an uncancellable step (a hung
            // ALTAppleAPI continuation or a stalled URLSession), so the install Task's release
            // may never run. If this key has been silent past the stale threshold, drop it and
            // service this beacon anyway.
            if now.timeIntervalSince(last) > BeaconListener.busyStaleAfter {
                log("beacon: previous install of \(bundle) silent >\(Int(BeaconListener.busyStaleAfter))s — clearing it")
                inFlight[key] = nil
                // fall through and handle this beacon normally
            } else {
                // A burst of beacons for the SAME app that's already installing is normal.
                sendStatus("Still updating — hang on…", to: from); return
            }
        }
        // A burst of packets is collapsed by `inFlight`: the first packet claims the key
        // synchronously on this queue, so the rest hit the branch above. A genuinely redundant
        // reinstall is short-circuited terminally inside the Task.
        guard let app = Tracked.all().first(where: { $0.udid == udid && $0.installedBundleID == bundle }) else {
            log("beacon from \(ip): no tracked app for \(bundle) on \(udid)"); return
        }
        inFlight[key] = now; lastPush[key] = now
        armWatchdog(key)   // release the key even if this install wedges — see armWatchdog()
        log("beacon from \(ip): \(bundle) — refreshing over Wi-Fi")
        sendStatus("Mac heard your request…", to: from)
        // Tell the device who is servicing it, so its popup can show "installed by
        // <this Mac>, signed by <Apple ID>" (spaces→underscores so the single-line
        // wire parser keeps them in one token).
        sendRaw("HOST \(Sideloader.computerName().replacingOccurrences(of: " ", with: "_"))\n", to: from)
        sendRaw("SIGNER \(app.appleID)\n", to: from)
        // Log closure that also forwards numbered step + fine "Now:" detail + upload % + ETA.
        var upStart: Date? = nil
        var lastProg = Date.distantPast
        var lastStep = 0
        let statusLog: (String) -> Void = { [weak self] msg in
            guard let self else { return }
            self.touchActivity(key)   // any line = the install is alive; keeps the watchdog from firing
            if msg.hasPrefix("PROGRESS ") {
                let p = msg.split(separator: " ")
                if p.count >= 3, let sent = Double(p[1]), let total = Double(p[2]), total > 0 {
                    if upStart == nil { upStart = Date() }
                    let now = Date(), done = sent >= total
                    if done || now.timeIntervalSince(lastProg) >= 0.7 {
                        lastProg = now
                        let pct = Int(min(100, sent / total * 100))
                        let elapsed = now.timeIntervalSince(upStart!)
                        let eta = (sent > 100_000 && elapsed > 1) ? Int((total - sent) / (sent / elapsed)) : -1
                        self.sendProgress(pct: pct, eta: eta, to: from)
                    }
                }
                return
            }
            self.log(msg)
            if msg.hasPrefix("PROFILE_EXPIRES ") {
                self.sendRaw("EXPIRES \(msg.dropFirst("PROFILE_EXPIRES ".count))\n", to: from)
                return
            }
            // Fine-grained "Now: …" detail for EVERY step, so the device popup shows exactly
            // where a self-update is (and where it hangs).
            self.sendRaw("NOW \(BeaconListener.nowDetail(msg))\n", to: from)
            // Numbered headline step ("n/6 Label") — only ever advances.
            if let (n, label) = BeaconListener.step(for: msg), n > lastStep {
                lastStep = n
                self.sendStatus("\(n)/\(BeaconListener.stepTotal)  \(label)", to: from)
            }
        }
        // Target the device by the IP this beacon came from — task-local, so concurrent beacon
        // installs each keep their own (the old process-wide setenv("IWISH_IP") let one beacon
        // redirect another's install) and nothing leaks into a later manual Refresh.
        Task { await Sideloader.$beaconIP.withValue(ip) {
            var released = false
            func release() {   // idempotent: free this key (normally right after the main install)
                guard !released else { return }
                released = true
                self.q.async { self.inFlight[key] = nil; self.lastPush[key] = Date() }
            }
            defer { release() }
            // Another app on this same device is installing → ours waits in InstallGate.devices.
            // Say so rather than leave the popup on "Mac heard your request…".
            if await InstallGate.deviceBusy(udid) {
                self.sendStatus("Queued behind another update on this device — starting in a moment…", to: from)
            }
            do {
                // Skip the reinstall when the installed signature is still fresh (<24h) and
                // the app's content hasn't changed — the device beacons on every launch,
                // including right after a manual install, so reinstalling then is pure churn.
                if await Sideloader.beaconReinstallIsRedundant(app) {
                    self.log("beacon: \(bundle) installed <24h ago and unchanged — skipping reinstall")
                    // The device treats a STATUS as terminal only if it contains
                    // "complete"/"relaunch"/"failed" (beacon_inject.m). A non-terminal reply
                    // leaves it beaconing forever — which kept `lastPush` fresh and made every
                    // later beacon (incl. a manual "Update app now") hit the 60s debounce,
                    // stuck on "Mac got your request…". So phrase this as terminal "complete".
                    self.sendStatus("Already up to date — no reinstall needed. Update check complete.", to: from)
                    return   // defer releases the key; device records success and stops
                }
                // Hard per-app deadline so a wedged step (stuck device install, hung
                // Apple API call) can never pin its key forever — which is what left
                // the device stuck on "Still updating — hang on…". On timeout this throws,
                // the key is released by the defer above, and the device retries on its next
                // beacon. The subprocess steps inside are separately bounded (ProcessWatchdog).
                _ = try await Sideloader.withTimeout(360, "Updating \(app.name)") {
                    try await Sideloader.refreshOne(app, log: statusLog)
                }
                // The install just updated the tracked version on disk — tell the UI to reload so
                // the app's version label reflects the build we just pushed, not the old cache.
                self.onInstalled?()
                // Completion is the ONE signal that makes the device exit-and-relaunch to
                // apply the new build (the "n/6" STATUS labels are not terminal). This used to
                // be a SINGLE best-effort UDP PROGRESS 100 — and the USB path doesn't stream
                // upload PROGRESS at all, so it never reached pct>=100. If that lone packet
                // dropped on Wi-Fi (or landed after the device's ~240s listen window), the
                // device never exited and its "Updating…" card froze at "6/6 Installing on your
                // device" forever. Fix: send the completion REDUNDANTLY (survives UDP loss) as
                // BOTH PROGRESS 100 and a terminal "relaunch" STATUS, so either path on the
                // device finishes the update. ("relaunch", not just "complete" — the up-to-date
                // skip path below says "complete" and must NOT trigger an exit.)
                for _ in 0..<5 {
                    self.sendProgress(pct: 100, eta: 0, to: from)
                    self.sendStatus("Update complete — relaunch to apply.", to: from)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                // This app is done — free its key now, so its relaunch beacon (or a manual
                // "Update app now") isn't answered "Still updating" while the cascade runs.
                release()
                // Cascade: while we have this device reachable, refresh other apps on it so
                // rarely-opened apps don't silently expire just because only one app beacons.
                // (10167702445) But ONLY those actually near expiry — refreshing EVERY sibling
                // on every beacon meant one "ready" beacon kicked off a full ~10-app reinstall.
                // Sequential + quiet (no beacon-UI for the extras); failures (incl. per-app
                // timeout) are logged, not fatal. Each sibling claims its own key, so a beacon
                // from that sibling meanwhile gets "Still updating" instead of a duplicate install,
                // and a sibling already being updated by its own beacon is skipped here.
                let cascadeWindow: TimeInterval = 2 * 86400   // refresh siblings due within 2 days
                let others = Tracked.all().filter {
                    $0.udid == udid && $0.installedBundleID != bundle
                    && ($0.secondsUntilExpiry ?? .greatestFiniteMagnitude) < cascadeWindow
                }
                if !others.isEmpty {
                    self.log("beacon cascade: also refreshing \(others.count) other app(s) on \(udid)")
                    for t in others {
                        let tk = "\(t.udid)|\(t.installedBundleID)"
                        guard self.claim(tk) else { self.log("cascade: \(t.name) already updating — skipped"); continue }
                        defer { self.unclaim(tk) }
                        do { _ = try await Sideloader.withTimeout(360, "Updating \(t.name)") { try await Sideloader.refreshOne(t, log: { self.touchActivity(tk); self.log("cascade[\(t.name)]: \($0)") }) } ; self.log("cascade: refreshed \(t.name)") }
                        catch { self.log("cascade: \(t.name) failed: \(error)") }
                    }
                    self.onInstalled?()   // cascade updated more tracked versions — reload the UI too
                }
            }
            catch { self.sendStatus("Update failed — will retry later.", to: from); self.log("beacon refresh failed: \(error)") }
        } }
    }

    // MARK: in-flight keys + watchdog

    /// Claim `key` from a Task (never call on `q`). False if it's already being updated.
    private func claim(_ key: String) -> Bool {
        q.sync {
            if let last = inFlight[key], Date().timeIntervalSince(last) <= BeaconListener.busyStaleAfter { return false }
            inFlight[key] = Date(); return true
        }
    }
    private func unclaim(_ key: String) { q.async { self.inFlight[key] = nil } }

    /// Time-based backstop for a wedged install. The install Task's release runs only if that
    /// Task finishes; the stale check in handle() runs only when the NEXT beacon for the same key
    /// arrives — but the device stops beaconing once it's answered, so in practice nothing
    /// arrives. This self-reschedules while the install keeps logging progress (its activity
    /// time advances) and drops the key once it has been SILENT for longer than busyStaleAfter.
    /// Keyed off activity, not wall-clock since start, so a slow-but-live install isn't cut off.
    private func armWatchdog(_ key: String) {
        q.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, let last = self.inFlight[key] else { return }
            if Date().timeIntervalSince(last) > BeaconListener.busyStaleAfter {
                self.log("beacon: install of \(key) silent >\(Int(BeaconListener.busyStaleAfter))s — watchdog releasing it")
                self.inFlight[key] = nil
            } else {
                self.armWatchdog(key)   // still installing and progressing — keep watching
            }
        }
    }

    /// Mark that the install for `key` just made progress. Hops to `q`, where `inFlight` lives,
    /// so the log callbacks (which fire off the cooperative pool) stay race-free.
    private func touchActivity(_ key: String) { q.async { if self.inFlight[key] != nil { self.inFlight[key] = Date() } } }

    // MARK: advertise

    private func advertise() {
        let svc = NetService(domain: "local.", type: "_sidestep._udp.", name: "SideStep", port: Int32(BeaconListener.port))
        // NetService needs a run loop; the app has one, and `Provision --listen` runs RunLoop.main.
        DispatchQueue.main.async {
            CrashLog.log("BeaconListener: NetService.publish() on main…")
            svc.publish()
            CrashLog.log("BeaconListener: NetService.publish() returned")
        }
        advertiser = svc
    }
}
