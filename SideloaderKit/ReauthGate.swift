// ReauthGate.swift — throttles UNATTENDED Apple ID re-logins (refresh daemon, beacon installs).
//
// Every unattended re-login sends the Keychain-saved password to Apple's GrandSlam servers.
// When Apple wants a 2-factor code, it pushes one to all of the account's trusted devices as
// part of the sign-in itself (hsc 409 without "au", see ALTAppleAPI+Authentication.swift) —
// before SideStep gets any chance to decline. Retrying on every refresh tick or beacon therefore
// shows the user a "Sign-In Requested" prompt every 1–5 minutes, on every trusted device.
// A locked account (-20209) is answered the same way on every attempt (250 attempts in one day
// were observed), and repeated sign-ins may well contribute to such locks in the first place.
//
// So, per Apple ID:
//   • Apple answered about the account itself (2FA needed, locked, credentials rejected):
//     no more unattended re-logins until the user signs in interactively (AccountStore.add
//     clears the gate).
//   • Anything else (network, anisette server, 5xx): exponential backoff, 15 min doubling up
//     to 6 h.
//   • Only one unattended re-login per Apple ID at a time, so a refresh and a beacon arriving
//     together can't trigger two pushes.
// The state is kept in UserDefaults so relaunching SideStep doesn't reset it.

import Foundation
import AltSign

public enum ReauthGate {
    public enum Verdict: Equatable {
        case allowed
        case blocked(String)
    }

    private struct Entry: Codable {
        var reason: String
        var failures: Int
        var until: Double?   // nil = blocked until the next interactive sign-in
    }

    private static let key = "sidestep.reauthGate"
    private static let lock = NSLock()
    private static var inFlight = Set<String>()
    static let baseDelay: TimeInterval = 15 * 60
    static let maxDelay: TimeInterval = 6 * 3600

    // MARK: attempts

    /// Call before an unattended re-login. `.allowed` reserves the attempt for this Apple ID;
    /// the caller must then call `finish(_:error:)` exactly once.
    public static func begin(_ appleID: String, now: Date = Date()) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        if inFlight.contains(appleID) { return .blocked("another automatic sign-in is already running") }
        if let e = load()[appleID] {
            guard let until = e.until else { return .blocked("\(e.reason) — open SideStep and sign in again") }
            let left = until - now.timeIntervalSince1970
            if left > 0 { return .blocked("\(e.reason) — next automatic try in \(Int(left / 60) + 1) min") }
        }
        inFlight.insert(appleID)
        return .allowed
    }

    /// Record the outcome of an attempt started with `begin`. Returns a log line for failures.
    @discardableResult
    public static func finish(_ appleID: String, error: Error?, now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(appleID)
        var m = load()
        guard let error else {
            if m.removeValue(forKey: appleID) != nil { save(m) }
            return ""
        }
        let n = (m[appleID]?.failures ?? 0) + 1
        let detail = describe(error)
        if let reason = needsUser(error) {
            m[appleID] = Entry(reason: reason, failures: n, until: nil)
            save(m)
            return "\(reason) (\(detail)) — automatic sign-in paused until you sign in again in SideStep"
        }
        let delay = min(baseDelay * pow(2, Double(n - 1)), maxDelay)
        m[appleID] = Entry(reason: "sign-in failed: \(detail)", failures: n, until: now.timeIntervalSince1970 + delay)
        save(m)
        return "\(detail) — next automatic try in \(Int(delay / 60)) min (failure \(n))"
    }

    /// Forget any pause for this Apple ID (after an interactive sign-in, or when it's removed).
    public static func clear(_ appleID: String) {
        lock.lock(); defer { lock.unlock() }
        var m = load()
        if m.removeValue(forKey: appleID) != nil { save(m) }
    }

    // MARK: classification

    /// Non-nil when Apple answered about the account itself, so retrying unattended can only
    /// produce more 2FA pushes or failed sign-ins: the user has to sign in interactively.
    static func needsUser(_ error: Error) -> String? {
        var apiError = error as? ALTAppleAPIError
        let ns = error as NSError
        if apiError == nil, ns.domain == ALTAppleAPIErrorDomain { apiError = ALTAppleAPIError(rawValue: ns.code) }
        switch apiError {
        case .requiresTwoFactorAuthentication?: return "Apple asked for a 2-factor code"
        case .incorrectCredentials?: return "Apple rejected the saved password"
        default: break
        }
        if ns.domain == ALTAppleAPI.twoFactorAskedAgainErrorDomain { return "Apple asked for a 2-factor code again" }
        if ns.domain == ALTUnderlyingAppleAPIErrorDomain {
            switch ns.code {
            case -20209: return "this Apple Account is locked"
            // Same "Apple answered about the account" set as Anisette.shouldRetryWithOtherIdentity.
            case -20101, -20970, -22406: return "Apple rejected the account details"
            default: break
            }
        }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let text = ns.localizedDescription
        let short = text.count > 160 ? String(text.prefix(160)) + "…" : text
        return "\(short) [\(ns.domain) \(ns.code)]"
    }

    // MARK: storage

    private static func load() -> [String: Entry] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: Entry].self, from: d) else { return [:] }
        return m
    }
    private static func save(_ m: [String: Entry]) {
        if m.isEmpty { UserDefaults.standard.removeObject(forKey: key); return }
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
    }
}
