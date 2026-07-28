// "Search AltStore" backend. Aggregates AltStore-format source catalogs (public JSON,
// no auth, no rate limit — unlike the GitHub API) and searches across them client-side.
// The default source list is fetched from SideStep's own repo (sources.json), so it can
// grow via pull requests; users can also add/remove their own source URLs.
import Foundation

public enum AltStoreCatalog {
    /// The PR-able default list lives in the repo.
    static let listURL = "https://raw.githubusercontent.com/johnbuckman/SideStep/main/sources.json"
    /// Used only if the remote list can't be fetched (offline first run).
    static let fallback = [
        "https://apps.altstore.io", "https://altstore.oatmealdome.me", "https://alt.getutm.app",
        "https://flyinghead.github.io/flycast-builds/altstore.json", "https://provenance-emu.com/apps.json",
        "https://pokemmo.com/altstore/", "https://ish.app/altstore.json"
    ]
    static let userKey = "sidestep.altstore.userSources"
    static let hiddenKey = "sidestep.altstore.hiddenDefaults"

    // MARK: - source URL management

    static func remoteDefaults() async -> [String] {
        if let u = URL(string: listURL), let (d, _) = try? await URLSession.shared.data(from: u),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let arr = obj["sources"] as? [String], !arr.isEmpty { return arr }
        return fallback
    }
    public static func userSources() -> [String] { UserDefaults.standard.stringArray(forKey: userKey) ?? [] }
    static func hidden() -> [String] { UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [] }

    public struct Source: Identifiable, Sendable { public let url: String; public let isDefault: Bool; public var id: String { url } }

    /// Default sources (minus ones the user hid) followed by the user's own, deduped.
    public static func effectiveSources() async -> [Source] {
        let h = Set(hidden()), us = userSources()
        var out = (await remoteDefaults()).filter { !h.contains($0) }.map { Source(url: $0, isDefault: true) }
        out += us.map { Source(url: $0, isDefault: false) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.url).inserted }
    }
    public static func addUserSource(_ raw: String) {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines); guard !u.isEmpty else { return }
        var us = userSources(); if !us.contains(u) { us.append(u); UserDefaults.standard.set(us, forKey: userKey) }
        UserDefaults.standard.set(hidden().filter { $0 != u }, forKey: hiddenKey)   // un-hide if it was a hidden default
        invalidate()
    }
    public static func removeSource(_ url: String) {
        let us = userSources()
        if us.contains(url) { UserDefaults.standard.set(us.filter { $0 != url }, forKey: userKey) }
        else { var h = hidden(); if !h.contains(url) { h.append(url); UserDefaults.standard.set(h, forKey: hiddenKey) } }
        invalidate()
    }

    // MARK: - apps

    nonisolated(unsafe) private static var cache: (apps: [SourceApp], at: Date)?
    static func invalidate() { cache = nil }

    /// All installable apps across the effective sources, merged + deduped by bundle id.
    public static func allApps(force: Bool = false) async -> [SourceApp] {
        if !force, let c = cache, Date().timeIntervalSince(c.at) < 600 { return c.apps }
        let urls = (await effectiveSources()).map { $0.url }
        var merged: [String: SourceApp] = [:]
        await withTaskGroup(of: [SourceApp].self) { group in
            for u in urls { group.addTask { await fetchOne(u) } }
            for await apps in group {
                for a in apps where !a.downloadURL.isEmpty && !a.bundleIdentifier.isEmpty {
                    if merged[a.bundleIdentifier] == nil { merged[a.bundleIdentifier] = a }
                }
            }
        }
        let list = merged.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        cache = (list, Date())
        return list
    }
    static func fetchOne(_ urlString: String) async -> [SourceApp] {
        guard let u = URL(string: urlString), let (d, _) = try? await URLSession.shared.data(from: u),
              let src = try? JSONDecoder().decode(AltSource.self, from: d) else { return [] }
        let sname = src.name ?? ""
        return src.apps.map { var a = $0; a.sourceName = sname; return a }
    }
    public static func search(_ q: String, in apps: [SourceApp]) -> [SourceApp] {
        let s = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(s)
            || ($0.developerName?.lowercased().contains(s) ?? false)
            || ($0.localizedDescription?.lowercased().contains(s) ?? false)
            || $0.sourceName.lowercased().contains(s)
        }
    }
}
