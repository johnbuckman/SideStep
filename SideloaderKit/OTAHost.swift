import Foundation
import Network
import Security

/// Serves an already-ad-hoc-signed `.ipa` for over-the-air (`itms-services`) install over
/// a trusted HTTPS URL, so a device can install it by scanning a QR code — no cable, no
/// inbound connection to the device. Uses the free **local-ip.co** service: it maps
/// `<dashed-lan-ip>.my.local-ip.co` → the Mac's LAN IP for anyone, and publishes a
/// publicly-trusted GlobalSign wildcard cert for `*.my.local-ip.co` that iOS accepts.
///
/// The IPA must already be ad-hoc/enterprise signed (`IPAInfo.otaCapable`); we don't
/// re-sign — we just host it. Verify end-to-end on a device (the TLS path can't be
/// exercised without one).
public final class OTAHost: @unchecked Sendable {
    public static let shared = OTAHost()
    private var listener: NWListener?
    private var serveDir: String = ""
    private var ipaName = "app.ipa"
    public private(set) var portalURL: URL?
    private let port: UInt16 = 8443

    // Install-progress tracking. Single session (one QR / one device at a time):
    // installd fetches manifest.plist then the .ipa from us, so we can report
    // "confirmed → downloading → downloaded" to the page, which polls /status.
    // (We can't see the final on-device install result — that's Level 2, an
    // app-launch ping — so "downloaded" is the last server-visible stage.)
    private let stateLock = NSLock()
    private var sawManifest = false, sawIPAStart = false, sawIPADone = false
    private var ipaSent: Int64 = 0, ipaTotal: Int64 = 0
    /// Called (off the main thread) on every progress change so the Mac UI can
    /// show a bar under the QR. Args: (stage, bytesSent, bytesTotal).
    public var onProgress: ((String, Int64, Int64) -> Void)?

    private func resetProgress() {
        stateLock.lock(); sawManifest = false; sawIPAStart = false; sawIPADone = false; ipaSent = 0; ipaTotal = 0; stateLock.unlock()
    }
    private func mark(manifest: Bool = false, ipaStart: Bool = false, ipaDone: Bool = false) {
        stateLock.lock()
        if manifest { sawManifest = true }; if ipaStart { sawIPAStart = true }; if ipaDone { sawIPADone = true }
        stateLock.unlock()
    }
    private func snapshot() -> (String, Int64, Int64) {
        stateLock.lock(); let m = sawManifest, s = sawIPAStart, d = sawIPADone, sent = ipaSent, total = ipaTotal; stateLock.unlock()
        let stage = d ? "downloaded" : (s ? "downloading" : (m ? "confirmed" : "waiting"))
        return (stage, sent, total)
    }
    private func report() { let (st, s, t) = snapshot(); onProgress?(st, s, t) }
    private func stageJSON() -> String {
        let (stage, sent, total) = snapshot()
        return "{\"stage\":\"\(stage)\",\"sent\":\(sent),\"total\":\(total)}"
    }

    // UDID capture (Profile Service): the device installs a tiny profile and iOS
    // POSTs its UDID back. Reuses the same trusted-HTTPS host over local-ip.co.
    public enum Mode { case install, udid }
    private var mode: Mode = .install
    public private(set) var capturedUDID: String?
    /// Called off the main thread when the device posts its UDID. (udid, product, version)
    public var onUDID: ((String, String, String) -> Void)?
    private var enrollBytes: Data?               // cached (signed) mobileconfig

    /// Stage <ipa> + manifest + a one-tap install page, start the HTTPS server, and return
    /// the portal URL to encode in a QR. Throws if the LAN IP or cert can't be obtained.
    public func start(ipaPath: String, info: IPAInfo) throws -> URL {
        stop()
        resetProgress()
        mode = .install
        guard let ip = Self.lanIPv4() else { throw err("Couldn't determine this Mac's Wi-Fi IP address.") }
        let host = ip.replacingOccurrences(of: ".", with: "-") + ".my.local-ip.co"

        // staging dir
        let dir = NSTemporaryDirectory() + "sidestep-ota-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        serveDir = dir
        ipaName = (safe(info.appName).isEmpty ? "app" : safe(info.appName)) + ".ipa"
        try FileManager.default.copyItem(atPath: ipaPath, toPath: dir + "/" + ipaName)

        let base = "https://\(host):\(port)"
        try manifest(info: info, ipaURL: "\(base)/\(ipaName)").write(toFile: dir + "/manifest.plist", atomically: true, encoding: .utf8)
        try page(info: info, manifestURL: "\(base)/manifest.plist").write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)

        // TLS identity from the local-ip.co cert, then listen.
        try listen(identity: try Self.localIPIdentity())
        let url = URL(string: "\(base)/")!
        portalURL = url
        return url
    }

    /// Start a UDID-capture host: the device opens the URL, installs a small
    /// Profile Service profile, and iOS POSTs its UDID back to us. Returns the
    /// URL to show as a QR / link. `onUDID` fires when the device reports in.
    public func startUDIDCapture() throws -> URL {
        stop()
        mode = .udid
        capturedUDID = nil
        enrollBytes = nil
        guard let ip = Self.lanIPv4() else { throw err("Couldn't determine this Mac's Wi-Fi IP address.") }
        let host = ip.replacingOccurrences(of: ".", with: "-") + ".my.local-ip.co"
        try listen(identity: try Self.localIPIdentity())
        let url = URL(string: "https://\(host):\(port)/")!
        portalURL = url
        return url
    }

    private func listen(identity: sec_identity_t) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let params = NWParameters(tls: tls)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: .global())
        listener = l
    }

    public func stop() {
        listener?.cancel(); listener = nil; portalURL = nil
        if !serveDir.isEmpty { try? FileManager.default.removeItem(atPath: serveDir); serveDir = "" }
    }

    // MARK: HTTP (minimal)

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        readRequest(conn, Data())
    }

    /// Accumulate the request until we have the full headers (and, for POST, the
    /// full body per Content-Length), then route. Needed because the Profile
    /// Service callback POSTs a multi-KB signed plist body.
    private func readRequest(_ conn: NWConnection, _ acc: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self else { conn.cancel(); return }
            var buf = acc
            if let data, !data.isEmpty { buf.append(data) }
            guard let hdrEnd = buf.firstRange(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || err != nil || buf.count > 2_000_000 { conn.cancel() }
                else { self.readRequest(conn, buf) }
                return
            }
            let header = String(decoding: buf[buf.startIndex..<hdrEnd.lowerBound], as: UTF8.self)
            let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
            let reqParts = (lines.first.map(String.init) ?? "").split(separator: " ")
            let method = reqParts.first.map(String.init) ?? "GET"
            let rawPath = reqParts.count >= 2 ? String(reqParts[1]) : "/"
            let path = rawPath == "/" ? "/" : String(rawPath.split(separator: "?").first ?? "/")
            var contentLength = 0
            for l in lines where l.lowercased().hasPrefix("content-length:") {
                contentLength = Int(l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            let bodyStart = hdrEnd.upperBound
            let haveBody = buf.endIndex - bodyStart
            if method == "POST" && haveBody < contentLength && !isComplete && err == nil && buf.count < 2_000_000 {
                self.readRequest(conn, buf); return
            }
            let body = Data(buf[bodyStart..<buf.endIndex])
            switch self.mode {
            case .install: self.serveInstall(path == "/" ? "/index.html" : path, on: conn)
            case .udid:    self.serveUDID(method, path, body, on: conn)
            }
        }
    }

    private func serveInstall(_ path: String, on conn: NWConnection) {
        // Progress endpoint the install page polls.
        if path == "/status" {
            let body = stageJSON().data(using: .utf8)!
            var h = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)!
            h.append(body)
            conn.send(content: h, completion: .contentProcessed { _ in conn.cancel() }); return
        }
        // installd fetches the manifest only after the user confirms the iOS
        // install dialog; then it pulls the .ipa. Track both.
        if path == "/manifest.plist" { mark(manifest: true); report() }
        let isIPA = path.hasSuffix(".ipa")

        let file = serveDir + path
        guard FileManager.default.fileExists(atPath: file), let body = FileManager.default.contents(atPath: file) else {
            let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() }); return
        }

        // The IPA is streamed in chunks so the Mac shows a real download bar.
        if isIPA {
            mark(ipaStart: true)
            stateLock.lock(); ipaSent = 0; ipaTotal = Int64(body.count); stateLock.unlock()
            report()
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)!
            conn.send(content: header, completion: .contentProcessed { [weak self] err in
                guard let self, err == nil else { conn.cancel(); return }
                self.sendIPAChunk(body, 0, conn)
            })
            return
        }

        let ctype = path.hasSuffix(".plist") ? "application/xml" : "text/html; charset=utf-8"
        var header = "HTTP/1.1 200 OK\r\nContent-Type: \(ctype)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)!
        header.append(body)
        conn.send(content: header, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Send the IPA body in 512 KB chunks, reporting cumulative bytes after each,
    /// so the Mac can render a determinate progress bar under the QR code.
    private func sendIPAChunk(_ data: Data, _ offset: Int, _ conn: NWConnection) {
        let chunkSize = 524_288
        let end = min(offset + chunkSize, data.count)
        let isLast = end >= data.count
        let chunk = data.subdata(in: offset..<end)
        conn.send(content: chunk, isComplete: isLast, completion: .contentProcessed { [weak self] err in
            guard let self, err == nil else { conn.cancel(); return }
            self.stateLock.lock(); self.ipaSent = Int64(end); self.stateLock.unlock()
            self.report()
            if isLast { self.mark(ipaDone: true); self.report(); conn.cancel() }
            else { self.sendIPAChunk(data, end, conn) }
        })
    }

    // MARK: UDID capture (Profile Service)

    private func serveUDID(_ method: String, _ path: String, _ body: Data, on conn: NWConnection) {
        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(enrollPage(), ctype: "text/html; charset=utf-8", on: conn)
        case ("GET", "/enroll.mobileconfig"):
            let data = enrollProfile()
            respond(data, ctype: "application/x-apple-aspen-config",
                    extraHeaders: "Content-Disposition: attachment; filename=\"register.mobileconfig\"\r\n", on: conn)
        case ("POST", "/enrolled"):
            let attrs = parseCallback(body)
            if let udid = attrs["UDID"], !udid.isEmpty {
                capturedUDID = udid
                onUDID?(udid, attrs["PRODUCT"] ?? "", attrs["VERSION"] ?? "")
            }
            respond(enrolledPage(ok: attrs["UDID"] != nil), ctype: "text/html; charset=utf-8", on: conn)
        case ("GET", "/status"):
            respond("{\"udid\":\"\(capturedUDID ?? "")\"}", ctype: "application/json", on: conn)
        default:
            let r = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func respond(_ text: String, ctype: String, extraHeaders: String = "", on conn: NWConnection) {
        respond(Data(text.utf8), ctype: ctype, extraHeaders: extraHeaders, on: conn)
    }
    private func respond(_ body: Data, ctype: String, extraHeaders: String = "", on conn: NWConnection) {
        var h = "HTTP/1.1 200 OK\r\nContent-Type: \(ctype)\r\nCache-Control: no-store\r\n\(extraHeaders)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)!
        h.append(body)
        conn.send(content: h, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// The Profile Service payload iOS installs, then POSTs the requested
    /// DeviceAttributes (UDID etc.) back to /enrolled.
    private func enrollProfilePlist() -> String {
        let callback = (portalURL?.absoluteString ?? "https://localhost/") + "enrolled"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>PayloadContent</key><dict>
            <key>URL</key><string>\(callback)</string>
            <key>DeviceAttributes</key><array>
              <string>UDID</string><string>PRODUCT</string><string>VERSION</string><string>DEVICE_NAME</string>
            </array>
          </dict>
          <key>PayloadOrganization</key><string>SideStep</string>
          <key>PayloadDisplayName</key><string>Register this device</string>
          <key>PayloadDescription</key><string>Sends this device's identifier so its apps can be signed for it.</string>
          <key>PayloadType</key><string>Profile Service</string>
          <key>PayloadVersion</key><integer>1</integer>
          <key>PayloadUUID</key><string>\(UUID().uuidString)</string>
          <key>PayloadIdentifier</key><string>com.decent.sidestep.enroll</string>
        </dict></plist>
        """
    }

    /// Sign the profile with the local-ip.co cert so iOS shows "Verified"; if
    /// signing fails, serve it unsigned (installs fine, shows "Unverified").
    private func enrollProfile() -> Data {
        if let cached = enrollBytes { return cached }
        let plist = enrollProfilePlist()
        var out = Data(plist.utf8)
        let tmp = NSTemporaryDirectory() + "sidestep-mc-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        func fetch(_ url: String, _ name: String) -> Bool {
            guard let u = URL(string: url), let d = try? Data(contentsOf: u), !d.isEmpty else { return false }
            return (try? d.write(to: URL(fileURLWithPath: tmp + "/" + name))) != nil
        }
        try? plist.write(toFile: tmp + "/p.plist", atomically: true, encoding: .utf8)
        if fetch("https://local-ip.co/cert/server.pem", "cert.pem"),
           fetch("https://local-ip.co/cert/server.key", "key.pem"),
           run("/usr/bin/openssl", ["smime", "-sign", "-signer", tmp + "/cert.pem", "-inkey", tmp + "/key.pem",
                "-nodetach", "-outform", "der", "-in", tmp + "/p.plist", "-out", tmp + "/signed.mobileconfig"]) == 0,
           let signed = FileManager.default.contents(atPath: tmp + "/signed.mobileconfig"), !signed.isEmpty {
            out = signed
        }
        enrollBytes = out
        return out
    }

    /// Parse the CMS/PKCS7-signed device-attributes plist iOS POSTs back.
    private func parseCallback(_ raw: Data) -> [String: String] {
        let tmp = NSTemporaryDirectory() + "sidestep-cb-" + UUID().uuidString + ".der"
        try? raw.write(to: URL(fileURLWithPath: tmp))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        var plist = runOut("/usr/bin/openssl", ["smime", "-verify", "-noverify", "-inform", "der", "-in", tmp])
        if plist.isEmpty { plist = String(decoding: raw, as: UTF8.self) }   // some clients POST raw
        var out: [String: String] = [:]
        for k in ["UDID", "PRODUCT", "VERSION", "DEVICE_NAME"] {
            if let m = plist.range(of: "<key>\(k)</key>"),
               let s = plist.range(of: "<string>", range: m.upperBound..<plist.endIndex),
               let e = plist.range(of: "</string>", range: s.upperBound..<plist.endIndex) {
                out[k] = String(plist[s.upperBound..<e.lowerBound])
            }
        }
        return out
    }

    private func enrollPage() -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="font-family:-apple-system;background:#16232f;color:#fff;text-align:center;padding:44px 24px">
        <h1 style="font-size:26px">Register this device</h1>
        <p style="color:#9fb0be">This sends your device's identifier to the Mac so its apps can be signed for it.</p>
        <p><a style="display:inline-block;margin-top:14px;padding:18px 30px;background:#22c1b6;color:#08202a;font-weight:700;border-radius:14px;text-decoration:none" href="/enroll.mobileconfig">Register this device</a></p>
        <div style="max-width:360px;margin:24px auto 0;padding:14px 16px;border:1px solid #2c3f4e;border-radius:12px;text-align:left">
          <div style="color:#E8A33D;font-weight:700;font-size:14px;margin-bottom:6px">After you tap the button</div>
          <div style="color:#9fb0be;font-size:14px;line-height:1.55">iOS downloads a profile. Open <b>Settings</b> &#9656; it shows <b>Profile Downloaded</b> &#9656; tap it (or Settings &#9656; General &#9656; VPN &amp; Device Management) &#9656; <b>Install</b> and enter your passcode. Then return here.</div>
        </div>
        <div id="s" style="margin-top:22px;color:#9fb0be;font-size:15px;min-height:22px"></div>
        <script>
        function p(){fetch('/status',{cache:'no-store'}).then(function(r){return r.json();}).then(function(j){if(j.udid){document.getElementById('s').textContent='Registered \\u2713 \\u2014 you can return to your Mac.';}});}
        setInterval(p,1500);p();
        </script>
        </body></html>
        """
    }

    private func enrolledPage(ok: Bool) -> String {
        let msg = ok ? "Registered \u{2713}" : "Couldn't read this device's identifier."
        let sub = ok ? "You can return to your Mac — its UDID now shows there." : "Please go back and try again."
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="font-family:-apple-system;background:#16232f;color:#fff;text-align:center;padding:60px 24px">
        <h1 style="font-size:26px">\(msg)</h1><p style="color:#9fb0be">\(sub)</p>
        </body></html>
        """
    }

    // MARK: content

    private func manifest(info: IPAInfo, ipaURL: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>items</key><array><dict>
          <key>assets</key><array><dict>
            <key>kind</key><string>software-package</string>
            <key>url</key><string>\(ipaURL)</string>
          </dict></array>
          <key>metadata</key><dict>
            <key>bundle-identifier</key><string>\(info.bundleID)</string>
            <key>bundle-version</key><string>\(info.version.isEmpty ? "1.0" : info.version)</string>
            <key>kind</key><string>software</string>
            <key>title</key><string>\(xml(info.appName))</string>
          </dict>
        </dict></array></dict></plist>
        """
    }

    private func page(info: IPAInfo, manifestURL: String) -> String {
        let link = "itms-services://?action=download-manifest&amp;url=\(manifestURL)"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="font-family:-apple-system;background:#16232f;color:#fff;text-align:center;padding:48px 24px">
        <h1 style="font-size:28px">\(xml(info.appName))</h1>
        <p style="color:#9fb0be">Tap to install over the air.</p>
        <p><a style="display:inline-block;margin-top:14px;padding:18px 30px;background:#22c1b6;color:#08202a;font-weight:700;border-radius:14px;text-decoration:none" href="\(link)">Install \(xml(info.appName))</a></p>
        <div style="max-width:360px;margin:26px auto 0;padding:14px 16px;border:1px solid #2c3f4e;border-radius:12px;text-align:left">
          <div style="color:#E8A33D;font-weight:700;font-size:14px;margin-bottom:6px">First time on this device only</div>
          <div style="color:#9fb0be;font-size:14px;line-height:1.55">On iOS&nbsp;16+, after installing, tap the app once. If it says Developer Mode is required, enable <b>Settings&nbsp;&#9656;&nbsp;Privacy&nbsp;&amp;&nbsp;Security&nbsp;&#9656;&nbsp;Developer&nbsp;Mode</b> (the device restarts), then open the app.</div>
        </div>
        <div id="otaStatus" style="margin-top:24px;color:#9fb0be;font-size:15px;min-height:22px">Waiting for you to tap Install above…</div>
        <div id="otaHint" style="display:none;max-width:360px;margin:12px auto 0;color:#6c7f8d;font-size:13px">Didn't appear? Enable Developer Mode (above) and make sure this device is registered in the profile.</div>
        <script>
        (function(){
          var m={waiting:"Waiting for you to tap Install above\\u2026",confirmed:"Install confirmed \\u2014 starting download\\u2026",downloading:"Downloading the app to your device\\u2026",downloaded:"Download complete \\u2014 the app will appear on your Home screen shortly."};
          var el=document.getElementById('otaStatus'),hint=document.getElementById('otaHint'),armed=false;
          function poll(){fetch('/status',{cache:'no-store'}).then(function(r){return r.json();}).then(function(j){if(m[j.stage])el.textContent=m[j.stage];if(j.stage==='downloaded'&&!armed){armed=true;setTimeout(function(){hint.style.display='block';},20000);}}).catch(function(){});}
          setInterval(poll,1200);poll();
        })();
        </script>
        </body></html>
        """
    }

    // MARK: helpers

    /// Build a `sec_identity_t` from the local-ip.co leaf cert+key plus the correct
    /// GlobalSign intermediate (fetched via the leaf's AIA), so iOS gets a full trusted chain.
    private static func localIPIdentity() throws -> sec_identity_t {
        let tmp = NSTemporaryDirectory() + "sidestep-cert-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        func fetch(_ url: String, _ name: String) throws {
            guard let u = URL(string: url), let d = try? Data(contentsOf: u), !d.isEmpty else { throw err("Couldn't fetch \(name).") }
            try d.write(to: URL(fileURLWithPath: tmp + "/" + name))
        }
        try fetch("https://local-ip.co/cert/server.pem", "server.pem")
        try fetch("https://local-ip.co/cert/server.key", "server.key")
        // the correct GlobalSign intermediate (local-ip.co's own chain.pem is stale/mismatched)
        // HTTPS (not the cert's http AIA URL): the bundled app enforces App Transport
        // Security, which blocks plain-http loads (NSURLError -1022) — the same file is
        // served over https, so this avoids an ATS exception.
        try fetch("https://secure.globalsign.com/cacert/gsgccr6alphasslca2025.crt", "inter.der")
        _ = run("/usr/bin/openssl", ["x509", "-inform", "der", "-in", tmp + "/inter.der", "-out", tmp + "/inter.pem"])
        // bundle leaf+key(+intermediate) into a PKCS12 to import as a SecIdentity
        _ = run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", tmp + "/server.key",
                "-in", tmp + "/server.pem", "-certfile", tmp + "/inter.pem",
                "-passout", "pass:sidestep", "-out", tmp + "/id.p12"])
        guard let p12 = FileManager.default.contents(atPath: tmp + "/id.p12") else { throw err("Couldn't build TLS identity.") }
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase as String: "sidestep"] as CFDictionary, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]], let first = arr.first,
              let idAny = first[kSecImportItemIdentity as String] else { throw err("TLS identity import failed (\(status)).") }
        let secIdentity = idAny as! SecIdentity
        // Present the full chain (leaf + GlobalSign intermediate) so iOS can validate;
        // sec_identity_create() alone sends only the leaf.
        if let interDER = FileManager.default.contents(atPath: tmp + "/inter.der"),
           let interCert = SecCertificateCreateWithData(nil, interDER as CFData),
           let sid = sec_identity_create_with_certificates(secIdentity, [interCert] as CFArray) {
            return sid
        }
        guard let sid = sec_identity_create(secIdentity) else { throw err("Couldn't create TLS identity.") }
        return sid
    }

    /// The Mac's IPv4 address on the primary Wi-Fi/Ethernet interface (en0/en1).
    static func lanIPv4() -> String? {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return nil }
        defer { freeifaddrs(ptr) }
        var best: String?
        var a: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = a {
            let ifa = cur.pointee
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if name == "en0" || name == "en1" {
                    var hn = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &hn, socklen_t(hn.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hn)
                        if ip.hasPrefix("169.254.") == false { if name == "en0" { return ip }; best = best ?? ip }
                    }
                }
            }
            a = ifa.ifa_next
        }
        return best
    }

    private func safe(_ s: String) -> String { s.components(separatedBy: CharacterSet.alphanumerics.inverted).joined() }
    private func xml(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
}

private func err(_ m: String) -> NSError { NSError(domain: "SideStep.OTAHost", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
@discardableResult private func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}
private func runOut(_ tool: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}
