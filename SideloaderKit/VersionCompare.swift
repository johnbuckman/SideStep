import Foundation

/// Version/tag comparison used by the self-updater (latest release tag vs installed
/// version) and by the GitHub-source refresh. Pulled out of the GUI target so it can be
/// unit-tested in isolation — a wrong comparison here means SideStep either never
/// self-updates or update-loops. Handles a leading "v", pre-release ranks
/// (alpha < beta < rc < release), and pads numeric components to three.
public enum VersionCompare {
    /// True iff `latest` is a strictly newer version/tag than `current`.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        key(current).lexicographicallyPrecedes(key(latest))
    }

    /// Sortable key: [major, minor, patch, prereleaseRank]. Exposed for tests.
    public static func key(_ tag: String) -> [Int] {
        var s = tag.lowercased()
        if s.hasPrefix("v") { s.removeFirst() }
        let rank = s.contains("alpha") ? 0 : s.contains("beta") ? 1 : (s.contains("rc") ? 2 : 3)
        let main = s.split(separator: "-").first.map(String.init) ?? s
        var nums = main.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        while nums.count < 3 { nums.append(0) }
        return Array(nums.prefix(3)) + [rank]
    }
}
