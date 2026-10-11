// Remote Anisette (SideStore "v3" protocol) — the fallback for when macOS won't
// hand Anisette to SideStep locally (macOS 27.2: akd rejects the XPC connection).
// The server only emulates Apple's device-identity (ADI) step: provisioning is
// relayed through it once, then it turns the saved adi.pb into one-time codes.
// The Apple ID and password never go to it — sign-in still talks to Apple directly.
// Protocol reference: SideStore/apple-private-apis omnisette/src/remote_anisette_v3.rs
import Foundation
import AltSign
import CryptoKit

public enum RemoteAnisette {
    public static let defaultServer = "https://ani.sidestore.io"
    /// Override (e.g. a self-hosted anisette-v3-server):
    ///   defaults write com.johnbuckman.sidestep anisetteServerURL https://host:port
    public static var serverURL: String {
        let s = UserDefaults.standard.string(forKey: "anisetteServerURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (s.isEmpty ? defaultServer : s).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Persisted per-Mac identity. adi_pb is this "virtual device"'s provisioning
    /// blob — device-identity material, so the file is owner-only and never logged.
    private struct State: Codable {
        var identifier: Data      // 16 random bytes
        var adiPB: Data?
        // Lowercase, as isideload/omnisette send it.
        var deviceID: String { identifier.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)).uuidString.lowercased() } }
        var localUserID: String { SHA256.hash(data: identifier).map { String(format: "%02x", $0) }.joined() }
    }
    private struct ClientInfo { let clientInfo: String; let userAgent: String }

    private static let lock = NSLock()
    /// User-Agent from the server's client_info, for requests made with its Anisette.
    public private(set) static var lastUserAgent: String?
    private static var statePath: String { (SideStepSupportDir as NSString).appendingPathComponent("anisette-v3.json") }
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    private static func fail(_ s: String) -> SideErr { .fail("remote Anisette (\(URL(string: serverURL)?.host ?? serverURL)): \(s)") }

    /// Fresh Anisette from the server, provisioning first if this Mac has no adi.pb yet.
    public static func fetch() throws -> ALTAnisetteData {
        lock.lock(); defer { lock.unlock() }
        let base = serverURL
        let info = try clientInfo(base)
        lastUserAgent = info.userAgent
        var st = loadState()
        if st.adiPB == nil {
            try provision(base, info, &st)
            saveState(st)
        }
        do {
            return try headers(base, info, st)
        } catch NotProvisioned.error {
            // Server says the saved adi.pb is no longer valid (-45061): provision again once.
            st.adiPB = nil
            try provision(base, info, &st)
            saveState(st)
            return try headers(base, info, st)
        }
    }

    private enum NotProvisioned: Error { case error }

    // MARK: state

    private static func loadState() -> State {
        if let d = FileManager.default.contents(atPath: statePath),
           let s = try? JSONDecoder().decode(State.self, from: d), s.identifier.count == 16 { return s }
        var id = Data(count: 16)
        _ = id.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return State(identifier: id, adiPB: nil)
    }
    private static func saveState(_ s: State) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(atPath: SideStepSupportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: statePath, contents: d, attributes: [.posixPermissions: 0o600])
    }

    // MARK: protocol steps

    private static func clientInfo(_ base: String) throws -> ClientInfo {
        guard let url = URL(string: base + "/v3/client_info") else { throw fail("invalid server URL") }
        let j = try json(send(URLRequest(url: url)).data)
        guard j["client_info"] is String, let ua = j["user_agent"] as? String else { throw fail("client_info missing fields") }
        // Servers still report a 2016 MacBook Pro on macOS 13.1, which Apple now only
        // offers SMS 2FA for and never finishes trusting. isideload hardcodes a current
        // Mac instead (nab138/isideload 232c7f3); with it Apple offers the trusted-device
        // prompt and accepts the follow-up sign-in.
        return ClientInfo(clientInfo: "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>", userAgent: ua)
    }

    private static func headers(_ base: String, _ info: ClientInfo, _ st: State) throws -> ALTAnisetteData {
        guard let url = URL(string: base + "/v3/get_headers"), let pb = st.adiPB else { throw fail("not provisioned") }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["identifier": st.identifier.base64EncodedString(),
                                                                 "adi_pb": pb.base64EncodedString()])
        // One retry: public servers occasionally answer with a gateway error page.
        var reply = try send(r, anyStatus: true)
        if (try? json(reply.data)) == nil {
            print("[SideStep] Anisette: get_headers returned HTTP \(reply.status) non-JSON; retrying once")
            Thread.sleep(forTimeInterval: 2)
            reply = try send(r, anyStatus: true)
        }
        guard let j = try? json(reply.data) else {
            // Not JSON, so not a headers payload — safe to show what the server said.
            let snippet = String(decoding: reply.data.prefix(120), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            throw fail("get_headers: HTTP \(reply.status), non-JSON reply\(snippet.isEmpty ? "" : ": \(snippet)")")
        }
        switch j["result"] as? String {
        case "Headers":
            guard let mdm = j["X-Apple-I-MD-M"] as? String, let md = j["X-Apple-I-MD"] as? String else { throw fail("headers missing X-Apple-I-MD/-MD-M") }
            let rinfo = (j["X-Apple-I-MD-RINFO"] as? String).flatMap { UInt64($0) } ?? (j["X-Apple-I-MD-RINFO"] as? NSNumber)?.uint64Value ?? 17106176
            return ALTAnisetteData(machineID: mdm, oneTimePassword: md, localUserID: st.localUserID,
                                   routingInfo: rinfo, deviceUniqueIdentifier: st.deviceID, deviceSerialNumber: "0",
                                   deviceDescription: info.clientInfo, date: Date(), locale: .current, timeZone: .current)
        case "GetHeadersError":
            let msg = j["message"] as? String ?? ""
            if msg.contains("-45061") { throw NotProvisioned.error }
            throw fail("get_headers: \(msg)")
        case let other:
            throw fail("get_headers: unexpected result \(other ?? "nil")")
        }
    }

    /// Relay Apple's provisioning exchange through the server's websocket; the
    /// server answers with the adi.pb for our identifier.
    private static func provision(_ base: String, _ info: ClientInfo, _ st: inout State) throws {
        print("[SideStep] Anisette: provisioning with \(URL(string: base)?.host ?? base)")
        let lookup = try plist(send(appleRequest("https://gsa.apple.com/grandslam/GsService2/lookup", info, st)).data)
        guard let urls = lookup["urls"] as? [String: Any],
              let startURL = urls["midStartProvisioning"] as? String,
              let endURL = urls["midFinishProvisioning"] as? String
        else { throw fail("Apple lookup returned no provisioning URLs") }

        guard var comps = URLComponents(string: base + "/v3/provisioning_session") else { throw fail("invalid server URL") }
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        guard let wsURL = comps.url else { throw fail("invalid server URL") }
        let ws = session.webSocketTask(with: wsURL)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        while true {
            let msg = try receive(ws)
            switch msg["result"] as? String {
            case "GiveIdentifier":
                try send(ws, ["identifier": st.identifier.base64EncodedString()])
            case "GiveStartProvisioningData":
                let body = try PropertyListSerialization.data(fromPropertyList: ["Header": [String: Any](), "Request": [String: Any]()], format: .xml, options: 0)
                let resp = try plist(send(appleRequest(startURL, info, st, body: body)).data)
                guard let spim = (resp["Response"] as? [String: Any])?["spim"] as? String else { throw fail("Apple start-provisioning returned no spim") }
                try send(ws, ["spim": spim])
            case "GiveEndProvisioningData":
                guard let cpim = msg["cpim"] as? String else { throw fail("server sent no cpim") }
                let body = try PropertyListSerialization.data(fromPropertyList: ["Header": [String: Any](), "Request": ["cpim": cpim]], format: .xml, options: 0)
                let resp = try plist(send(appleRequest(endURL, info, st, body: body)).data)
                guard let r = resp["Response"] as? [String: Any], let ptm = r["ptm"] as? String, let tk = r["tk"] as? String
                else { throw fail("Apple finish-provisioning returned no ptm/tk") }
                try send(ws, ["ptm": ptm, "tk": tk])
            case "ProvisioningSuccess":
                guard let s = msg["adi_pb"] as? String, let pb = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines))
                else { throw fail("server sent no adi_pb") }
                st.adiPB = pb
                print("[SideStep] Anisette: provisioned")
                return
            case "Wait", "CurrentlyStartingProvisioning", "CurrentlyEndingProvisioning", "TextOnly":
                continue
            case let other:
                throw fail("provisioning: \(other ?? "nil")\((msg["message"] as? String).map { " — \($0)" } ?? "")")
            }
        }
    }

    private static func appleRequest(_ url: String, _ info: ClientInfo, _ st: State, body: Data? = nil) throws -> URLRequest {
        guard let u = URL(string: url) else { throw fail("bad Apple URL") }
        var r = URLRequest(url: u)
        r.httpMethod = body == nil ? "GET" : "POST"
        r.httpBody = body
        // isideload's provisioning headers (GrandSlam base headers + LU + device id).
        let headers = ["X-Mme-Client-Info": info.clientInfo, "User-Agent": info.userAgent,
                       "Content-Type": "text/x-xml-plist", "Accept": "text/x-xml-plist",
                       "X-Xcode-Version": "27.0 (27A5218g)", "X-Apple-App-Info": "com.apple.gs.xcode.auth",
                       "X-Apple-I-MD-LU": st.localUserID, "X-Mme-Device-Id": st.deviceID]
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    // MARK: synchronous transport (Anisette.fresh() is synchronous and runs off the main thread)

    private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private static func send(_ req: URLRequest, anyStatus: Bool = false) throws -> (data: Data, status: Int) {
        let sem = DispatchSemaphore(value: 0)
        let out = Box<Result<(data: Data, status: Int), Error>>(.failure(fail("no response")))
        let host = req.url?.host ?? "?"
        session.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let err { out.value = .failure(fail("\(host): \(err.localizedDescription)")) }
            else if !anyStatus, !(200..<300).contains(status) { out.value = .failure(fail("HTTP \(status) from \(host)")) }
            else { out.value = .success((data ?? Data(), status)) }
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + 30) == .timedOut { throw SideErr.timeout("remote Anisette: timed out talking to \(host)") }
        return try out.value.get()
    }

    private static func receive(_ ws: URLSessionWebSocketTask) throws -> [String: Any] {
        let sem = DispatchSemaphore(value: 0)
        let out = Box<Result<URLSessionWebSocketTask.Message, Error>>(.failure(fail("no message")))
        ws.receive { r in out.value = r; sem.signal() }
        if sem.wait(timeout: .now() + 30) == .timedOut { throw SideErr.timeout("remote Anisette: provisioning timed out") }
        switch try out.value.get() {
        case .string(let s): return try json(Data(s.utf8))
        case .data(let d): return try json(d)
        @unknown default: throw fail("unexpected websocket message")
        }
    }

    private static func send(_ ws: URLSessionWebSocketTask, _ obj: [String: String]) throws {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let sem = DispatchSemaphore(value: 0)
        let out = Box<Error?>(nil)
        ws.send(.string(text)) { e in out.value = e; sem.signal() }
        if sem.wait(timeout: .now() + 30) == .timedOut { throw SideErr.timeout("remote Anisette: provisioning timed out") }
        if let e = out.value { throw fail("websocket: \(e.localizedDescription)") }
    }

    private static func json(_ d: Data) throws -> [String: Any] {
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw fail("server reply isn't JSON") }
        return j
    }
    private static func plist(_ d: Data) throws -> [String: Any] {
        guard let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { throw fail("Apple reply isn't a plist") }
        return p
    }
}
