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
    private var currentKey: String? = nil        // the (udid|bundleid) currently installing, if any
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

    /// Map an internal install log line to a friendly device-facing status, or nil.
    private static func friendly(_ msg: String) -> String? {
        if msg.contains("Registering") || msg.contains("Team:")        { return "Preparing your update…" }
        if msg.contains("App ID") || msg.contains("profile")           { return "Getting a signing profile…" }
        if msg.contains("Signing")                                      { return "Signing the app…" }
        if msg.contains("Installing by direct IP") || msg.contains("uploaded") { return "Sending the new app to your device…" }
        if msg.contains("INSTALL OK") || msg.contains("Installed ")     { return "Update complete — relaunching…" }
        return nil
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
        let key = "\(udid)|\(bundle)"
        let now = Date()
        if busy {
            // A burst of beacons for the SAME app that's already installing is normal —
            // don't cry "another update". Only a DIFFERENT device/app is really blocked.
            if key == currentKey { sendStatus("Still updating — hang on…", to: from) }
            else { sendStatus("Mac is busy with another update — hold on…", to: from) }
            return
        }
        if let last = lastPush[key], now.timeIntervalSince(last) < 60 {
            sendStatus("Mac got your request — just a moment…", to: from); return
        }
        guard let app = Tracked.all().first(where: { $0.udid == udid && $0.installedBundleID == bundle }) else {
            log("beacon from \(ip): no tracked app for \(bundle) on \(udid)"); return
        }
        busy = true; currentKey = key; lastPush[key] = now
        log("beacon from \(ip): \(bundle) — refreshing over Wi-Fi")
        sendStatus("Mac heard your request…", to: from)
        setenv("IWISH_IP", ip, 1)   // target the device by the IP the beacon came from
        // Log closure that also forwards friendly status + upload % + ETA to the device.
        var upStart: Date? = nil
        var lastProg = Date.distantPast
        let statusLog: (String) -> Void = { [weak self] msg in
            guard let self else { return }
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
            if let f = BeaconListener.friendly(msg) { self.sendStatus(f, to: from) }
        }
        Task {
            // Clear the target IP when done so it can't leak into a later manual
            // Refresh (which must route by the device's live connection type).
            defer { unsetenv("IWISH_IP") }
            defer { self.q.async { self.busy = false; self.currentKey = nil; self.lastPush[key] = Date() } }
            do {
                _ = try await Sideloader.refreshOne(app, log: statusLog)
                // The USB path doesn't stream upload PROGRESS, so the on-device beacon
                // never reaches the pct>=100 that triggers its exit-to-apply-the-swap.
                // Send a final 100% on success so the app relaunches into the new build
                // no matter which transport was used.
                self.sendProgress(pct: 100, eta: 0, to: from)
            }
            catch { self.sendStatus("Update failed — will retry later.", to: from); self.log("beacon refresh failed: \(error)") }
        }
    }

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
