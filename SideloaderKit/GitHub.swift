// GitHub Releases as an app source. SideStep can install the newest `.ipa` from a
// repo's releases, keep it updated (the tracked app remembers its repo + tag), and
// search GitHub for repos that ship an installable `.ipa`.
//
// Uses the public, unauthenticated GitHub API (no token): 60 core req/hr and
// 10 search req/min per IP — fine for occasional installs + a daily update sweep.
import Foundation

public enum GitHub {
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
        var req = URLRequest(url: u)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SideStep", forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
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

    /// Download an `.ipa` to a temp file; returns its local path.
    public static func downloadIPA(_ rel: IPARelease) async throws -> String {
        let (tmp, _) = try await URLSession.shared.download(from: rel.ipaURL)
        let safe = rel.ipaName.replacingOccurrences(of: "/", with: "_")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)-\(safe)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
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
}
