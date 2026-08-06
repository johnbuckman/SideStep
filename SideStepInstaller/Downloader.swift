//
//  Downloader — fetch the latest SideStep from GitHub Releases and install it.
//
//  The installer ships no copy of SideStep; it downloads the current notarized build
//  so users never get a stale SideStep baked into someone's installer. Adapted from
//  SideStep's own UpdateChecker (same download → mount/extract → verify path).
//

import Foundation
import AppKit

enum Downloader {
    static let releasesAPI = URL(string: "https://api.github.com/repos/johnbuckman/SideStep/releases")!
    static let releasesPage = URL(string: "https://github.com/johnbuckman/SideStep/releases")!
    static let requiredTeamID = "CDZD6VH5KL"   // any downloaded SideStep must be signed by this Developer ID

    enum Result { case installed(URL), failure(String) }

    /// Ensure a verified SideStep is in /Applications and return its path. If one is
    /// already installed we use it (fast, and never clobbers a running copy); otherwise
    /// we download the latest release, verify it's notarized + our team, and install it.
    static func ensureSideStep(progress: @escaping (String) -> Void) async -> Result {
        let fm = FileManager.default
        let sys = URL(fileURLWithPath: "/Applications/SideStep.app")
        let user = fm.urls(for: .applicationDirectory, in: .userDomainMask).first?.appendingPathComponent("SideStep.app")
        for existing in [sys, user].compactMap({ $0 }) where fm.fileExists(atPath: existing.path) {
            progress("SideStep is already installed.")
            launch(existing)
            return .installed(existing)
        }

        progress("Finding the latest SideStep…")
        guard let asset = await latestAssetURL() else {
            return .failure("Couldn’t find the latest SideStep release on GitHub.")
        }
        progress("Downloading SideStep…")
        guard let app = await downloadAndVerify(asset) else {
            return .failure("The download couldn’t be verified as an official, notarized SideStep.")
        }
        progress("Installing SideStep…")
        do {
            let dst = try install(from: app)
            launch(dst)
            return .installed(dst)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: release lookup

    private static func latestAssetURL() async -> URL? {
        var req = URLRequest(url: releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let assets = first["assets"] as? [[String: Any]] else { return nil }
        func asset(_ suffix: String) -> URL? {
            guard let a = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(suffix) == true }),
                  let s = a["browser_download_url"] as? String else { return nil }
            return URL(string: s)
        }
        return asset(".dmg") ?? asset(".zip")
    }

    // MARK: download + verify (never run from the mount / archive)

    private static func downloadAndVerify(_ assetURL: URL) async -> URL? {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidestep-dl-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        guard let (tmp, _) = try? await URLSession.shared.download(from: assetURL) else { return nil }
        let isDMG = assetURL.pathExtension.lowercased() == "dmg"
        let asset = work.appendingPathComponent("asset." + (isDMG ? "dmg" : "zip"))
        try? fm.moveItem(at: tmp, to: asset)

        let extractDir = work.appendingPathComponent("x")
        try? fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        var appPath: URL?
        if isDMG {
            let mnt = work.appendingPathComponent("mnt")
            _ = await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-quiet", "-mountpoint", mnt.path, asset.path])
            if let name = (try? fm.contentsOfDirectory(atPath: mnt.path))?.first(where: { $0.hasSuffix(".app") }) {
                let dest = extractDir.appendingPathComponent(name)
                _ = await run("/usr/bin/ditto", [mnt.appendingPathComponent(name).path, dest.path])
                appPath = dest
            }
            _ = await run("/usr/bin/hdiutil", ["detach", "-quiet", mnt.path])
        } else {
            _ = await run("/usr/bin/ditto", ["-x", "-k", asset.path, extractDir.path])
            if let name = (try? fm.contentsOfDirectory(atPath: extractDir.path))?.first(where: { $0.hasSuffix(".app") }) {
                appPath = extractDir.appendingPathComponent(name)
            }
        }
        guard let appPath, fm.fileExists(atPath: appPath.path) else { return nil }
        // Must be Gatekeeper-accepted (notarized) AND signed by our Developer ID team.
        let assess = await run("/usr/sbin/spctl", ["--assess", "--type", "exec", "-v", appPath.path])
        guard assess.lowercased().contains("accepted") else { return nil }
        let cs = await run("/usr/bin/codesign", ["-dv", "--verbose=4", appPath.path])
        guard cs.contains("TeamIdentifier=\(requiredTeamID)") else { return nil }
        return appPath
    }

    // MARK: install into /Applications (fall back to ~/Applications)

    private static func install(from verifiedApp: URL) throws -> URL {
        let fm = FileManager.default
        // Quit any running SideStep so its bundle isn't busy when we replace it.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.johnbuckman.sidestep") {
            app.terminate()
        }
        usleep(500_000)
        let sys = URL(fileURLWithPath: "/Applications/SideStep.app")
        let user = fm.urls(for: .applicationDirectory, in: .userDomainMask).first?.appendingPathComponent("SideStep.app")
        var lastErr = "no writable Applications folder"
        for dst in [sys, user].compactMap({ $0 }) {
            do {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: verifiedApp, to: dst)
                // Downloaded → quarantined; strip it so the first launch doesn't prompt.
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                                     arguments: ["-dr", "com.apple.quarantine", dst.path])
                return dst
            } catch { lastErr = error.localizedDescription }
        }
        throw NSError(domain: "SideStepInstaller", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: lastErr])
    }

    static func launch(_ app: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false   // installed SideStep is a menu-bar app; don't steal focus
        NSWorkspace.shared.openApplication(at: app, configuration: cfg, completionHandler: nil)
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            } catch { cont.resume(returning: "") }
        }
    }
}
