// GitHub Releases as an app source. SideStep can install the newest `.ipa` from a
// repo's releases, keep it updated (the tracked app remembers its repo + tag), and
// search GitHub for repos that ship an installable `.ipa`.
//
// Uses the public GitHub API. Unauthenticated it's 60 core req/hr + 10 search
// req/min per IP — fine for occasional installs, but a wide search (which probes
// ~20 repos) can exhaust it. If the user has saved a personal-access token (stored
// in the Keychain), we send it as a Bearer token and the ceiling jumps to 5000/hr.
import Foundation
import Security

public enum GitHub {
    // MARK: - Personal-access token (Keychain-backed, optional)
    // A GitHub PAT lifts the rate limit from 60→5000 req/hr. Stored the same way as
    // the Apple-ID password so it survives launches and never sits in UserDefaults.
    private static let tokenService = "com.decent.sidestep.github"
    private static let tokenAccount = "pat"

    /// The URL where a user creates a token (fine-grained; public-repo read is enough).
    public static let createTokenURL = "https://github.com/settings/tokens?type=beta"

    /// Set when a saved token is rejected by GitHub (bad/expired, or blocked by an org
    /// policy such as forbidding long-lived fine-grained PATs) — carries GitHub's own
    /// explanation. nil when the token works or none is saved. The UI surfaces it so the
    /// user can fix the token instead of silently running at the lower unauth limit.
    public static var tokenRejection: String?

    public static func token() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: tokenService,
                                kSecAttrAccount as String: tokenAccount,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }
    public static var hasToken: Bool { token() != nil }
    public static func saveToken(_ t: String) {
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tokenService,
                                    kSecAttrAccount as String: tokenAccount]
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty else { return }   // empty = clear
        var add = base; add[kSecValueData as String] = trimmed.data(using: .utf8)!
        SecItemAdd(add as CFDictionary, nil)
    }
    public static func clearToken() { saveToken("") }

    /// Verify a token by calling /user; returns the login on success, nil if rejected.
    public static func verifyToken(_ t: String) async -> String? {
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: "https://api.github.com/user") else { return nil }
        var req = URLRequest(url: u)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SideStep", forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj["login"] as? String
    }

    /// A repo's newest release that carries an `.ipa` asset.
    public struct IPARelease: Sendable {
        public let repo: String      // "owner/name"
        public let tag: String
        public let ipaName: String
        public let ipaURL: URL
    }
    /// A search result: a repo, its description, and its latest `.ipa` (if any).
    public struct RepoHit: Identifiable, Sendable {
        public let repo: String
        public let description: String
        public let ipa: IPARelease?
        public var id: String { repo }
    }

    private static func apiJSON(_ urlString: String) async -> Any? {
        guard let u = URL(string: urlString) else { return nil }
        func fetch(useToken: Bool) async -> (json: Any?, status: Int) {
            var req = URLRequest(url: u)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("SideStep", forHTTPHeaderField: "User-Agent")
            if useToken, let t = token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
            guard let (d, resp) = try? await URLSession.shared.data(for: req) else { return (nil, 0) }
            return (try? JSONSerialization.jsonObject(with: d), (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let first = await fetch(useToken: true)
        if first.status == 200, token() != nil { tokenRejection = nil }   // token works → clear any warning
        // A saved token that a repo/org rejects — bad/expired (401) OR blocked by org
        // policy (403, e.g. an org that forbids long-lived fine-grained PATs) — returns a
        // JSON *object*, not the array callers expect, and would break every lookup. Fall
        // back to unauthenticated so PUBLIC-repo lookups keep working regardless.
        if (first.status == 401 || first.status == 403), token() != nil {
            let msg = (first.json as? [String: Any])?["message"] as? String ?? ""
            // A rate-limit 403 is NOT a token problem (the token is valid, just throttled),
            // so don't flag it as a bad token. Anything else = the token was rejected.
            if !msg.lowercased().contains("rate limit") {
                tokenRejection = msg.isEmpty ? "GitHub rejected your saved token (HTTP \(first.status))." : msg
            }
            let retry = await fetch(useToken: false)
            if retry.json is [Any] || retry.json is [String: Any] { return retry.json }
        }
        return first.json
    }

    /// Remaining unauthenticated "core" API requests this hour (the budget that the
    /// per-repo release probes spend). Querying /rate_limit is itself free. nil = unknown.
    public static func coreRemaining() async -> Int? {
        guard let obj = await apiJSON("https://api.github.com/rate_limit") as? [String: Any],
              let res = obj["resources"] as? [String: Any],
              let core = res["core"] as? [String: Any],
              let rem = core["remaining"] as? Int else { return nil }
        return rem
    }

    /// Normalize user input to "owner/name": accepts "owner/name" or a github.com URL.
    public static func normalizeRepo(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "github.com/") { s = String(s[r.upperBound...]) }
        s = s.replacingOccurrences(of: ".git", with: "")
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// The newest release (releases are newest-first) that has an `.ipa` asset.
    public static func latestIPA(repo: String) async -> IPARelease? {
        guard let arr = await apiJSON("https://api.github.com/repos/\(repo)/releases") as? [[String: Any]] else { return nil }
        for rel in arr {
            guard let tag = rel["tag_name"] as? String, let assets = rel["assets"] as? [[String: Any]] else { continue }
            if let a = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }),
               let name = a["name"] as? String,
               let s = a["browser_download_url"] as? String, let url = URL(string: s) {
                return IPARelease(repo: repo, tag: tag, ipaName: name, ipaURL: url)
            }
        }
        return nil
    }

    /// Download an `.ipa` to a temp file; returns its local path. `onProgress` reports
    /// (bytesReceived, bytesExpected) so the caller can show a % bar + ETA.
    public static func downloadIPA(_ rel: IPARelease,
                                   onProgress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void = { _, _ in }) async throws -> String {
        let safe = rel.ipaName.replacingOccurrences(of: "/", with: "_")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)-\(safe)")
        try await Sideloader.downloadFile(from: rel.ipaURL, to: dest, onProgress: onProgress)
        return dest.path
    }

    /// Search repositories by keyword, then keep the ones whose latest release ships
    /// an `.ipa` (each kept hit costs one extra API call, so `limit` is small).
    public static func searchReposWithIPA(_ query: String, scan: Int = 20) async -> [RepoHit] {
        // NOTE: GitHub's search API indexes repo name/description/README/topics, NOT
        // release assets — there is no way to query "repos whose releases contain an
        // .ipa". So we keyword-match repos, then probe each for an .ipa (one API call
        // each). `scan` bounds how many candidates we probe against the rate limit.
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let obj = await apiJSON("https://api.github.com/search/repositories?q=\(q)&per_page=\(scan)") as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return [] }
        var hits: [RepoHit] = []
        for it in items.prefix(scan) {
            guard let full = it["full_name"] as? String else { continue }
            if let ipa = await latestIPA(repo: full) {
                hits.append(RepoHit(repo: full, description: (it["description"] as? String) ?? "", ipa: ipa))
            }
        }
        return hits
    }

    /// List a GitHub user's (or org's) public repos whose latest release contains an
    /// .ipa. One API call for the repo list + one per repo probed; `scan` bounds the
    /// probes against the rate limit.
    public static func userReposWithIPA(_ user: String, scan: Int = 30) async -> [RepoHit] {
        let u = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
        guard let items = await apiJSON("https://api.github.com/users/\(u)/repos?per_page=100&sort=updated&type=owner") as? [[String: Any]] else { return [] }
        var hits: [RepoHit] = []
        for it in items.prefix(scan) {
            guard let full = it["full_name"] as? String else { continue }
            if let ipa = await latestIPA(repo: full) {
                hits.append(RepoHit(repo: full, description: (it["description"] as? String) ?? "", ipa: ipa))
            }
        }
        return hits
    }
}
