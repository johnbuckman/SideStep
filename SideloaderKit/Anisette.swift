// Anisette = the "X-Apple-I-MD" one-time headers Apple requires on every Apple-ID
// sign-in. Two sources, tried in order:
//
//  1. LOCAL — this Mac's own AOSKit/AuthKit (private frameworks). Works through macOS 26.
//     On macOS 27 `adid` refuses non-Apple-entitled callers ("CNE!", AOSKit logs
//     "Info request failed: -45070") and AOSUtilities returns no headers (GitHub issue #6).
//  2. REMOTE — an anisette-v3 server (github.com/Dadoum/anisette-v3-server) that serves
//     Windows (iTunes) anisette. The server never sees the Apple ID or password: it only
//     runs Apple's ADI code. On first use this Mac provisions its own virtual device
//     (identifier + adi.pb, kept in ~/Library/Application Support/SideStep/anisette-v3.json),
//     relaying the provisioning messages between the server and Apple; after that each
//     sign-in is one POST /v3/get_headers. Protocol ported from SideStore's
//     FetchAnisetteDataOperation.swift.
//
// Everything here is synchronous (callers are a mix of main-thread, GCD and async code)
// and the remote path deliberately uses completion-handler URLSession + semaphores rather
// than async/await, so blocking a caller can never starve Swift's cooperative thread pool.
import Foundation
import AltSign
import CryptoKit
import Network

public enum Anisette {
    /// Since 2026-10-12 Apple rejects anisette generated with Android's CoreADI (-80045 with a Mac
    /// client info; since 2026-10-14 HTTP 503 for any Android client info). Only anisette from
    /// Windows' iTunes ADI is accepted, and only when X-MMe-Client-Info and User-Agent are the
    /// ones the anisette server reports for that client (AltStore 22f766d, AltSign PR #61).
    /// So: use Windows anisette-v3 servers and send their own client_info/user_agent.
    public static let defaultServer = "https://ani.jkcoxson.com"
    /// Other Windows anisette servers, tried when the default one fails.
    static let backupServers = ["https://ani2.stikstore.app"]
    private static let serverKey = "sidestep.anisetteServer"

    /// Posted (on any thread) whenever `lastFailure` changes, so the UI can show/clear it.
    public static let problemChanged = Notification.Name("SideStepAnisetteProblemChanged")

    /// The anisette server used when this Mac can't generate anisette itself.
    public static var serverURL: String {
        get { UserDefaults.standard.string(forKey: serverKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultServer }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty || v == defaultServer { UserDefaults.standard.removeObject(forKey: serverKey) }
            else { UserDefaults.standard.set(v, forKey: serverKey) }
        }
    }

    /// User-facing explanation of the most recent failure; nil once anisette works again.
    public private(set) static var lastFailure: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastFailure }
        set {
            stateLock.lock(); let changed = _lastFailure != newValue; _lastFailure = newValue; stateLock.unlock()
            if changed { NotificationCenter.default.post(name: problemChanged, object: nil) }
        }
    }
    private static var _lastFailure: String?
    private static let stateLock = NSLock()

    /// Serializes fresh() so concurrent callers don't provision the same server twice.
    private static let freshLock = NSLock()
    /// After the local path fails, skip it for a while (it can't recover without an OS change,
    /// and each failed attempt costs a short wait for AOSKit's log line).
    private static var localBrokenUntil = Date.distantPast

    public static func fresh() -> ALTAnisetteData? {
        freshLock.lock(); defer { freshLock.unlock() }
        var localWhy = "skipped (failed in the last 10 minutes)"
        // SIDESTEP_REMOTE_ANISETTE=1 forces the server path (to test it on a Mac where local works).
        let forceRemote = ProcessInfo.processInfo.environment["SIDESTEP_REMOTE_ANISETTE"] == "1"
        if forceRemote { localWhy = "skipped (SIDESTEP_REMOTE_ANISETTE=1)" }
        if !forceRemote && Date() >= localBrokenUntil {
            switch local() {
            case .success(let a):
                lastFailure = nil
                // This Mac's own anisette: drop any server-specific settings a server fetch left in
                // AltSign (server User-Agent, resync/refresh via the server) so they can't leak into
                // a sign-in that uses local data.
                ALTAppleAPI.authenticationUserAgent = nil
                ALTAppleAPI.anisetteResyncHandler = nil
                ALTAppleAPI.anisetteRefreshHandler = nil
                return a
            case .failure(let why):
                localWhy = why
                localBrokenUntil = Date().addingTimeInterval(600)
                print("[SideStep anisette] local anisette failed on \(macOSVersion): \(why) — trying anisette server")
            }
        }
        var remoteErrs: [String] = []
        // Public anisette servers are often overloaded (502s, timeouts, and provisioning
        // messages landing on a different backend → "unknown session (-45025)"), so retry
        // each one a few times before moving on.
        for server in candidateServers() {
            var why = ""
            for attempt in 1...3 {
                do {
                    let a = try Remote(server: server).fetch()
                    print("[SideStep anisette] using anisette server \(server)")
                    lastFailure = nil
                    return a
                } catch {
                    why = (error as? SideErr)?.errorDescription ?? error.localizedDescription
                    print("[SideStep anisette] anisette server \(server) failed (try \(attempt)/3): \(why)")
                    if attempt < 3 { Thread.sleep(forTimeInterval: Double(attempt)) }
                }
            }
            remoteErrs.append("\(host(server)): \(why)")
        }
        let msg = "Couldn’t get Apple’s sign-in data (“anisette”) on macOS \(macOSVersion). "
            + "This Mac: \(localWhy). Anisette server — \(remoteErrs.joined(separator: "; ")). "
            + "Check your internet connection, or set a different anisette server in SideStep ▸ Settings."
        print("[SideStep anisette] FAILED: \(msg)")
        lastFailure = msg
        return nil
    }

    static func candidateServers() -> [String] {
        let s = serverURL
        return s == defaultServer ? [s] + backupServers : [s, defaultServer] + backupServers
    }

    public static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static func host(_ server: String) -> String { URL(string: server)?.host ?? server }

    // MARK: - Local (AOSKit / AuthKit)

    private static let loaded: Bool = {
        dlopen("/System/Library/PrivateFrameworks/AOSKit.framework/AOSKit", RTLD_NOW)
        dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW)
        return true
    }()

    private enum LocalResult { case success(ALTAnisetteData), failure(String) }

    private static func local() -> LocalResult {
        _ = loaded
        guard let aos = NSClassFromString("AOSUtilities") else { return .failure("AOSKit couldn’t be loaded") }
        guard let cls = NSClassFromString("AKDevice"),
              let dev = (cls as AnyObject).perform(NSSelectorFromString("currentDevice"))?.takeUnretainedValue()
        else { return .failure("AuthKit device info unavailable") }
        let codeMark = aosCodeMark()
        let r = (aos as AnyObject).perform(NSSelectorFromString("retrieveOTPHeadersForDSID:"), with: "-2")
        // Read values individually: a whole-dictionary `as? [String: String]` cast fails if
        // any value isn't a string.
        let otp = r?.takeUnretainedValue() as? NSDictionary
        guard let md = otp?["X-Apple-MD"] as? String, let mdm = otp?["X-Apple-MD-M"] as? String else {
            // AOSKit reports why only in its own log output (NSLog → our stderr pipe); give
            // the pipe reader a moment to hand us that line.
            var code = aosCode(after: codeMark)
            for _ in 0..<6 where code == nil { Thread.sleep(forTimeInterval: 0.05); code = aosCode(after: codeMark) }
            var why = "macOS returned no headers"
            if let code { why += " (AOSKit error \(code))" }
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                why += " — macOS 27 no longer lets non-Apple apps generate it"
            }
            return .failure(why)
        }
        let desc = (dev.value(forKey: "serverFriendlyDescription") as? String) ?? "<Mac> <macOS;26.2;25C56> <com.apple.AuthKit/1>"
        let devUUID = (dev.value(forKey: "uniqueDeviceIdentifier") as? String) ?? UUID().uuidString
        let luUUID = (dev.value(forKey: "localUserUUID") as? String) ?? UUID().uuidString
        let serial = (dev.value(forKey: "serialNumber") as? String) ?? "0"
        return .success(ALTAnisetteData(machineID: mdm, oneTimePassword: md, localUserID: sha256Hex(Data(luUUID.utf8)),
                                        routingInfo: 17106176, deviceUniqueIdentifier: devUUID, deviceSerialNumber: serial,
                                        deviceDescription: desc, date: Date(), locale: .current, timeZone: .current))
    }

    // AOSKit's error code arrives via the app's stdout/stderr pipe: the log reader calls
    // noteLogLine for every line. A sequence number tells codes from this attempt apart
    // from older ones.
    private static let codeLock = NSLock()
    private static var codeSeq = 0
    private static var lastCode: (seq: Int, code: String)?

    /// Feed one line of the process's own log output (the app's stderr pipe reader calls this).
    public static func noteLogLine(_ line: String) {
        guard line.contains("AOSKit"), let r = line.range(of: #"failed: (-?\d+)"#, options: .regularExpression) else { return }
        let code = line[r].replacingOccurrences(of: "failed: ", with: "")
        codeLock.lock(); codeSeq += 1; lastCode = (codeSeq, code); codeLock.unlock()
    }
    private static func aosCodeMark() -> Int { codeLock.lock(); defer { codeLock.unlock() }; return codeSeq }
    private static func aosCode(after mark: Int) -> String? {
        codeLock.lock(); defer { codeLock.unlock() }
        guard let c = lastCode, c.seq > mark else { return nil }
        return c.code
    }

    static func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Remote (anisette-v3 server)

    /// This Mac's provisioning state per server: a random 16-byte identifier (base64) and,
    /// once provisioned, the adi.pb blob the server hands back.
    struct V3State: Codable { var identifier: String; var adiPb: String?; var clientInfo: String? = nil }
    private static let statePath = SideStepSupportDir + "/anisette-v3.json"
    static func loadState(_ server: String) -> V3State? {
        guard let d = FileManager.default.contents(atPath: statePath),
              let all = try? JSONDecoder().decode([String: V3State].self, from: d) else { return nil }
        return all[server]
    }
    static func saveState(_ s: V3State, _ server: String) {
        var all: [String: V3State] = [:]
        if let d = FileManager.default.contents(atPath: statePath),
           let m = try? JSONDecoder().decode([String: V3State].self, from: d) { all = m }
        all[server] = s
        guard let d = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(atPath: SideStepSupportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: statePath, contents: d, attributes: [.posixPermissions: 0o600])
    }

    struct Remote {
        let server: String
        let base: URL
        let session: URLSession
        init(server: String) {
            self.server = server
            self.base = URL(string: server) ?? URL(string: Anisette.defaultServer)!
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: cfg)
        }

        func fetch() throws -> ALTAnisetteData {
            guard base.scheme == "https" || base.scheme == "http" else { throw SideErr.fail("not an http(s) URL") }
            defer { session.finishTasksAndInvalidate() }
            let info = try clientInfo()
            var state = Anisette.loadState(server) ?? V3State(identifier: Self.newIdentifier(), adiPb: nil)
            // An identity provisioned under a different client info (e.g. an old Android/Mac one) is
            // useless now: start a fresh identity for this server's client.
            if state.clientInfo != info.clientInfo {
                state = V3State(identifier: Self.newIdentifier(), adiPb: nil, clientInfo: info.clientInfo)
            }
            if state.adiPb == nil {
                state.adiPb = try provision(identifier: state.identifier, info: info)
                Anisette.saveState(state, server)
            }
            // GrandSlam only accepts the User-Agent of the client that generated the anisette.
            ALTAppleAPI.authenticationUserAgent = info.userAgent
            // On hsc 434 (anisette out of sync) AltSign asks us once for resynchronized anisette.
            let srv = server
            ALTAppleAPI.anisetteResyncHandler = { sim, done in
                DispatchQueue.global().async {
                    do { done(try Remote(server: srv).resync(sim: sim), nil) }
                    catch { done(nil, error) }
                }
            }
            ALTAppleAPI.anisetteRefreshHandler = { done in
                DispatchQueue.global().async {
                    do { done(try Remote(server: srv).fetch(), nil) }
                    catch { done(nil, error) }
                }
            }
            do {
                return try headers(state, info)
            } catch SideErr.fail(let m) where m.contains("-45061") {
                // -45061 = "not provisioned": the server no longer accepts our adi.pb. Re-provision once.
                print("[SideStep anisette] \(Anisette.host(server)) says not provisioned — re-provisioning")
                state.adiPb = try provision(identifier: state.identifier, info: info)
                Anisette.saveState(state, server)
                return try headers(state, info)
            }
        }

        /// Fresh headers for the already provisioned identity, resynchronized with Apple's
        /// X-Apple-I-MD-DATA from an hsc 434 answer.
        func resync(sim: String) throws -> ALTAnisetteData {
            defer { session.finishTasksAndInvalidate() }
            let info = try clientInfo()
            guard let state = Anisette.loadState(server), state.adiPb != nil else { throw SideErr.fail("resync: not provisioned") }
            print("[SideStep anisette] resynchronizing with \(Anisette.host(server)) (hsc 434)")
            return try headers(state, info, sim: sim)
        }

        static func newIdentifier() -> String {
            var b = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
            return Data(b).base64EncodedString()
        }

        struct ClientInfo { let clientInfo, userAgent: String }

        /// GET /v3/client_info → the device description + User-Agent the server's ADI emulates.
        func clientInfo() throws -> ClientInfo {
            let (d, _) = try send(URLRequest(url: base.appendingPathComponent("v3/client_info")))
            guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ci = j["client_info"] as? String, let ua = j["user_agent"] as? String
            else { throw SideErr.fail("not an anisette-v3 server (no client_info)") }
            let override = ProcessInfo.processInfo.environment["SIDESTEP_ANISETTE_CLIENTINFO"]
            guard override != nil || ci.contains("<Windows;") else {
                throw SideErr.fail("not a Windows anisette server (client_info \(ci)) — Apple only accepts Windows anisette now")
            }
            return ClientInfo(clientInfo: override ?? ci, userAgent: ua)
        }

        func identity(_ identifier: String) -> (mdLu: String, deviceID: String) {
            let raw = Data(base64Encoded: identifier) ?? Data(count: 16)
            let uuid = raw.count >= 16 ? raw.withUnsafeBytes { NSUUID(uuidBytes: $0.bindMemory(to: UInt8.self).baseAddress!) as UUID } : UUID()
            return (Anisette.sha256Hex(raw), uuid.uuidString.uppercased())
        }

        /// POST /v3/get_headers {identifier, adi_pb} → X-Apple-I-MD / -MD-M / -MD-RINFO.
        func headers(_ s: V3State, _ info: ClientInfo, sim: String? = nil) throws -> ALTAnisetteData {
            var req = URLRequest(url: base.appendingPathComponent("v3/get_headers"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["identifier": s.identifier, "adi_pb": s.adiPb ?? ""]
            if let sim {
                // Resync after GrandSlam hsc 434: pass Apple's X-Apple-I-MD-DATA plus our device ids
                // (as AltStore 22f766d does).
                let id = identity(s.identifier)
                body["sim"] = sim; body["device_id"] = id.deviceID; body["md_lu"] = id.mdLu
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (d, _) = try send(req)
            guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw SideErr.fail("get_headers returned non-JSON") }
            if (j["result"] as? String) == "GetHeadersError" { throw SideErr.fail("get_headers: \(j["message"] as? String ?? "error")") }
            guard let md = j["X-Apple-I-MD"] as? String, let mdm = j["X-Apple-I-MD-M"] as? String
            else { throw SideErr.fail("get_headers returned no headers") }
            let rinfo = (j["X-Apple-I-MD-RINFO"] as? String).flatMap { UInt64($0) } ?? 17106176
            let id = identity(s.identifier)
            return ALTAnisetteData(machineID: mdm, oneTimePassword: md, localUserID: id.mdLu, routingInfo: rinfo,
                                   deviceUniqueIdentifier: id.deviceID, deviceSerialNumber: "0",
                                   deviceDescription: info.clientInfo, date: Date(), locale: .current, timeZone: .current)
        }

        /// One-time provisioning of this Mac's virtual device: a WebSocket conversation with the
        /// server (/v3/provisioning_session), relaying its start/end messages to Apple's
        /// midStartProvisioning / midFinishProvisioning endpoints. Returns adi.pb.
        func provision(identifier: String, info: ClientInfo) throws -> String {
            print("[SideStep anisette] provisioning with \(Anisette.host(server))…")
            let id = identity(identifier)
            // Apple's provisioning endpoints
            let (ld, _) = try send(appleRequest(URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!, info, id))
            guard let lp = try? PropertyListSerialization.propertyList(from: ld, format: nil) as? [String: Any],
                  let urls = lp["urls"] as? [String: Any],
                  let startURL = (urls["midStartProvisioning"] as? String).flatMap(URL.init(string:)),
                  let endURL = (urls["midFinishProvisioning"] as? String).flatMap(URL.init(string:))
            else { throw SideErr.fail("Apple’s provisioning lookup failed") }

            var wsURL = URLComponents(url: base.appendingPathComponent("v3/provisioning_session"), resolvingAgainstBaseURL: false)!
            wsURL.scheme = (wsURL.scheme == "http") ? "ws" : "wss"
            let ws = try WebSocket(wsURL.url!)
            defer { ws.close() }

            for _ in 0..<10 {
                let msg = try ws.receiveJSON()
                guard let result = msg["result"] as? String else { throw SideErr.fail("provisioning: server sent no result") }
                switch result {
                case "GiveIdentifier":
                    try ws.sendJSON(["identifier": identifier])
                case "GiveStartProvisioningData":
                    let body: [String: Any] = ["Header": [String: Any](), "Request": [String: Any]()]
                    let r = try applePlist(startURL, body, info, id)
                    guard let spim = r["spim"] as? String else { throw SideErr.fail("Apple gave no start-provisioning data") }
                    try ws.sendJSON(["spim": spim])
                case "GiveEndProvisioningData":
                    guard let cpim = msg["cpim"] as? String else { throw SideErr.fail("provisioning: server gave no cpim") }
                    let body: [String: Any] = ["Header": [String: Any](), "Request": ["cpim": cpim]]
                    let r = try applePlist(endURL, body, info, id)
                    guard let ptm = r["ptm"] as? String, let tk = r["tk"] as? String
                    else { throw SideErr.fail("Apple gave no end-provisioning data") }
                    try ws.sendJSON(["ptm": ptm, "tk": tk])
                case "ProvisioningSuccess":
                    guard let adi = msg["adi_pb"] as? String else { throw SideErr.fail("provisioning: server gave no adi.pb") }
                    print("[SideStep anisette] provisioned with \(Anisette.host(server))")
                    return adi
                default:
                    throw SideErr.fail("provisioning: \(result)\((msg["message"] as? String).map { " — \($0)" } ?? "")")
                }
            }
            throw SideErr.fail("provisioning: too many steps")
        }

        func appleRequest(_ url: URL, _ info: ClientInfo, _ id: (mdLu: String, deviceID: String)) -> URLRequest {
            var r = URLRequest(url: url)
            r.setValue(info.clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
            r.setValue(info.userAgent, forHTTPHeaderField: "User-Agent")
            r.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
            r.setValue("*/*", forHTTPHeaderField: "Accept")
            r.setValue(id.mdLu, forHTTPHeaderField: "X-Apple-I-MD-LU")
            r.setValue(id.deviceID, forHTTPHeaderField: "X-Mme-Device-Id")
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            r.setValue(f.string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
            r.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
            r.setValue(TimeZone.current.abbreviation(), forHTTPHeaderField: "X-Apple-I-TimeZone")
            return r
        }

        /// POST an XML plist to Apple and return its "Response" dictionary.
        func applePlist(_ url: URL, _ body: [String: Any], _ info: ClientInfo, _ id: (mdLu: String, deviceID: String)) throws -> [String: Any] {
            var r = appleRequest(url, info, id)
            r.httpMethod = "POST"
            r.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
            let (d, _) = try send(r)
            guard let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
                  let resp = p["Response"] as? [String: Any] else { throw SideErr.fail("Apple returned an unreadable provisioning reply") }
            return resp
        }

        // MARK: blocking helpers

        func send(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
            let sem = DispatchSemaphore(value: 0)
            var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
            session.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
            if sem.wait(timeout: .now() + 20) == .timedOut { throw SideErr.timeout("\(req.url?.host ?? "server") didn’t answer") }
            if let e = out.2 { throw SideErr.fail(e.localizedDescription) }
            guard let http = out.1 as? HTTPURLResponse, let d = out.0 else { throw SideErr.fail("no response") }
            guard (200..<300).contains(http.statusCode) else { throw SideErr.fail("HTTP \(http.statusCode) from \(req.url?.host ?? "server")") }
            return (d, http)
        }
    }

    /// Minimal blocking WebSocket client on Network.framework. Not URLSessionWebSocketTask:
    /// that negotiates HTTP/2, and SideStore's nginx answers an HTTP/2 WebSocket with 502
    /// ("Socket is not connected"); NWProtocolWebSocket does a plain HTTP/1.1 upgrade.
    final class WebSocket {
        private let conn: NWConnection
        private let q = DispatchQueue(label: "com.decent.sidestep.anisette-ws")

        init(_ url: URL) throws {
            let params: NWParameters = url.scheme == "wss" ? .tls : .tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            conn = NWConnection(to: .url(url), using: params)
            let sem = DispatchSemaphore(value: 0)
            var failure: Error?
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: sem.signal()
                case .failed(let e), .waiting(let e): failure = e; sem.signal()
                default: break
                }
            }
            conn.start(queue: q)
            if sem.wait(timeout: .now() + 20) == .timedOut { conn.cancel(); throw SideErr.timeout("provisioning: couldn’t connect to the server") }
            conn.stateUpdateHandler = nil
            if let failure { conn.cancel(); throw SideErr.fail("provisioning connection: \(failure.localizedDescription)") }
        }

        func close() { conn.cancel() }

        func receiveJSON() throws -> [String: Any] {
            let sem = DispatchSemaphore(value: 0)
            var data: Data?, err: Error?, closed = false
            conn.receiveMessage { d, ctx, _, e in
                data = d; err = e
                let md = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                closed = md?.opcode == .close
                sem.signal()
            }
            if sem.wait(timeout: .now() + 20) == .timedOut { throw SideErr.timeout("provisioning: server stopped answering") }
            if let err { throw SideErr.fail("provisioning connection: \(err.localizedDescription)") }
            if closed { throw SideErr.fail("provisioning: server closed the connection") }
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw SideErr.fail("provisioning: server sent non-JSON") }
            return j
        }

        func sendJSON(_ obj: [String: String]) throws {
            let d = try JSONSerialization.data(withJSONObject: obj)
            let ctx = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            let sem = DispatchSemaphore(value: 0)
            var err: Error?
            conn.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { err = $0; sem.signal() })
            if sem.wait(timeout: .now() + 20) == .timedOut { throw SideErr.timeout("provisioning: send timed out") }
            if let err { throw SideErr.fail("provisioning connection: \(err.localizedDescription)") }
        }
    }
}
