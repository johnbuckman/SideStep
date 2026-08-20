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
    private var busy = false
    private var busyStartedAt = Date.distantPast // when `busy` was set — used to self-heal a wedged install
    // Slightly above the 360s per-app withTimeout so a normal (even slow) install never trips it,
    // but a permanently-wedged install (uncancellable Apple-API/URLSession hang that withTimeout
    // can't actually abandon) can't pin `busy` on forever and lock out every other device.
    private static let busyStaleAfter: TimeInterval = 420
    private var currentKey: String? = nil        // the (udid|bundleid) currently installing, if any
    private var lastActivityAt = Date.distantPast // last time the running install logged progress
    private var lastPush: [String: Date] = [:]   // per (udid|bundleid), debounce the packet burst
    private var log: (String) -> Void = { _ in }

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
        if busy {
            // Self-heal: `withTimeout(360)` can't truly abandon an uncancellable step (a hung
            // ALTAppleAPI continuation or a stalled URLSession), so the install Task's
            // busy-reset defer may never run and `busy` would stay pinned for the life of the
            // process — locking out every device with "Mac is busy…". If busy has been held
            // past the stale threshold, clear it and service this beacon anyway.
            if Date().timeIntervalSince(lastActivityAt) > BeaconListener.busyStaleAfter {
                log("beacon: previous install silent >\(Int(BeaconListener.busyStaleAfter))s — clearing stuck busy flag")
                busy = false; currentKey = nil
                // fall through and handle this beacon normally
            }
            // A burst of beacons for the SAME app that's already installing is normal —
            // don't cry "another update". Only a DIFFERENT device/app is really blocked.
            else if key == currentKey { sendStatus("Still updating — hang on…", to: from); return }
            else { sendStatus("Mac is busy with another update — hold on…", to: from); return }
        }
        // (Removed the old 60s "Mac got your request — just a moment…" debounce: it was a
        // NON-terminal reply that dropped the beacon and did no work, so the device popup hung
        // on it with no follow-up — especially right after an install, when lastPush is fresh.
        // A burst of packets is already collapsed by the `busy` flag below — the first packet
        // flips busy synchronously on this queue, so the rest fall into the busy branch above —
        // and a genuinely redundant reinstall is short-circuited terminally inside the Task.)
        guard let app = Tracked.all().first(where: { $0.udid == udid && $0.installedBundleID == bundle }) else {
            log("beacon from \(ip): no tracked app for \(bundle) on \(udid)"); return
        }
        busy = true; busyStartedAt = now; lastActivityAt = now; currentKey = key; lastPush[key] = now
        armBusyWatchdog()   // release `busy` even if this install wedges — see armBusyWatchdog()
        log("beacon from \(ip): \(bundle) — refreshing over Wi-Fi")
        sendStatus("Mac heard your request…", to: from)
        // Tell the device who is servicing it, so its popup can show "installed by
        // <this Mac>, signed by <Apple ID>" (spaces→underscores so the single-line
        // wire parser keeps them in one token).
        sendRaw("HOST \(Sideloader.computerName().replacingOccurrences(of: " ", with: "_"))\n", to: from)
        sendRaw("SIGNER \(app.appleID)\n", to: from)
        setenv("IWISH_IP", ip, 1)   // target the device by the IP the beacon came from
        // Log closure that also forwards numbered step + fine "Now:" detail + upload % + ETA.
        var upStart: Date? = nil
        var lastProg = Date.distantPast
        var lastStep = 0
        let statusLog: (String) -> Void = { [weak self] msg in
            guard let self else { return }
            self.touchActivity()   // any line = the install is alive; keeps the watchdog from firing
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
        Task {
            // Clear the target IP when done so it can't leak into a later manual
            // Refresh (which must route by the device's live connection type).
            defer { unsetenv("IWISH_IP") }
            defer { self.q.async { self.busy = false; self.currentKey = nil; self.lastPush[key] = Date() } }
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
                    return   // defers reset busy + IWISH_IP; device records success and stops
                }
                // Hard per-app deadline so a wedged step (stuck device install, hung
                // Apple API call) can never pin `busy` on forever — which is what left
                // the device stuck on "Still updating — hang on…". On timeout this throws,
                // `busy` is reset by the defer above, and the device retries on its next
                // beacon. The subprocess steps inside are separately bounded (ProcessWatchdog).
                _ = try await Sideloader.withTimeout(360, "Updating \(app.name)") {
                    try await Sideloader.refreshOne(app, log: statusLog)
                }
                // The USB path doesn't stream upload PROGRESS, so the on-device beacon
                // never reaches the pct>=100 that triggers its exit-to-apply-the-swap.
                // Send a final 100% on success so the app relaunches into the new build
                // no matter which transport was used.
                self.sendProgress(pct: 100, eta: 0, to: from)
                // Cascade: while we have this device reachable, refresh other apps on it so
                // rarely-opened apps don't silently expire just because only one app beacons.
                // (10167702445) But ONLY those actually near expiry — refreshing EVERY sibling
                // on every beacon meant one "ready" beacon kicked off a full ~10-app reinstall,
                // pinning `busy` for many minutes and leaving the triggering app's popup stuck
                // on "Still updating — hang on…" the whole time. Sequential + quiet (no beacon-UI
                // for the extras); failures (incl. per-app timeout) are logged, not fatal.
                let cascadeWindow: TimeInterval = 2 * 86400   // refresh siblings due within 2 days
                let others = Tracked.all().filter {
                    $0.udid == udid && $0.installedBundleID != bundle
                    && ($0.secondsUntilExpiry ?? .greatestFiniteMagnitude) < cascadeWindow
                }
                if !others.isEmpty {
                    self.log("beacon cascade: also refreshing \(others.count) other app(s) on \(udid)")
                    for t in others {
                        do { _ = try await Sideloader.withTimeout(360, "Updating \(t.name)") { try await Sideloader.refreshOne(t, log: { self.touchActivity(); self.log("cascade[\(t.name)]: \($0)") }) } ; self.log("cascade: refreshed \(t.name)") }
                        catch { self.log("cascade: \(t.name) failed: \(error)") }
                    }
                }
            }
            catch { self.sendStatus("Update failed — will retry later.", to: from); self.log("beacon refresh failed: \(error)") }
        }
    }

    // MARK: busy watchdog

    /// Time-based backstop for a wedged install. The install Task's `defer { busy = false }`
    /// runs only if that Task finishes; the beacon-triggered stale check in handle() runs only
    /// when the NEXT beacon arrives — but the device stops beaconing the moment it's told "Mac is
    /// busy", so in practice nothing arrives and `busy` stays pinned until SideStep is restarted
    /// (the reported bug). This self-reschedules while the install keeps logging progress
    /// (lastActivityAt advances) and force-clears `busy` once the install has been SILENT — no
    /// log or upload progress — for longer than busyStaleAfter. Distinguishing silence from a
    /// slow-but-live cascade is why we key off activity, not wall-clock since start.
    private func armBusyWatchdog() {
        q.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.busy else { return }
            if Date().timeIntervalSince(self.lastActivityAt) > BeaconListener.busyStaleAfter {
                self.log("beacon: install silent >\(Int(BeaconListener.busyStaleAfter))s — watchdog clearing stuck busy flag")
                self.busy = false; self.currentKey = nil
            } else {
                self.armBusyWatchdog()   // still installing and progressing — keep watching
            }
        }
    }

    /// Mark that the running install just made progress. Hops to `q`, where `busy` and the
    /// timestamps live, so the log callbacks (which fire off the cooperative pool) stay race-free.
    private func touchActivity() { q.async { self.lastActivityAt = Date() } }

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
