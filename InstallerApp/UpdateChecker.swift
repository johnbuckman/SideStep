import Foundation
import AppKit
import SideloaderKit

/// In-app auto-update, ported from MacCVS's UpdateChecker. No Sparkle, no appcast,
/// no server — just GitHub Releases plus a two-part signature check against our own
/// Team ID, so a spoofed release can't hijack the swap. Adapted for SideStep, whose
/// release asset is a notarized **`.dmg`** (a `.zip` of the .app is also accepted).
///
/// Safety model: the only thing between "downloaded a random file" and "replaced my
/// own app bundle" is `spctl --assess` (must be notarized) + a `TeamIdentifier` pin
/// (must be signed by *us*). Both must pass or we bail to the Releases page.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let releasesAPI = URL(string: "https://api.github.com/repos/johnbuckman/SideStep/releases")!
    private let releasesPage = URL(string: "https://github.com/johnbuckman/SideStep/releases")!
    private let lastCheckKey = "sidestep.lastUpdateCheck"
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private let teamID = "CDZD6VH5KL"   // required Developer ID team of any downloaded build
    private var busy = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    struct Release { let tag: String; let name: String; let assetURL: URL }

    // MARK: - Scheduling

    /// Run a check if 24h have passed since the last one (call at launch).
    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        guard let release = await fetchLatestRelease() else {
            if userInitiated {
                let rateLimited = (await GitHub.coreRemaining()).map { $0 < 2 } ?? false
                let text = rateLimited
                    ? "SideStep checks for updates through GitHub, and GitHub’s hourly request limit for this network is used up (60 requests/hour without a sign-in). This usually clears within the hour. You can wait and try again, or download the latest version directly from the Releases page."
                    : "SideStep couldn’t reach GitHub to check for a new version — likely no internet connection, or GitHub is briefly unavailable. Check your connection and try again, or download the latest version directly from the Releases page."
                let a = NSAlert()
                a.messageText = "Couldn’t Check for Updates"
                a.informativeText = text
                a.addButton(withTitle: "Open Releases Page")
                a.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releasesPage) }
            }
            return
        }
        if isNewer(release.tag, than: currentVersion) {
            presentUpdate(release)
        } else if userInitiated {
            alert("You’re Up to Date", "SideStep \(currentVersion) is the latest version.")
        }
    }

    // MARK: - GitHub

    private func fetchLatestRelease() async -> Release? {
        var req = URLRequest(url: releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SideStep", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,                                   // releases are newest-first
              let tag = first["tag_name"] as? String,
              let assets = first["assets"] as? [[String: Any]] else { return nil }
        // Prefer a .dmg (what we ship); accept a .zip of the .app as well.
        func asset(_ suffix: String) -> URL? {
            guard let a = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(suffix) == true }),
                  let s = a["browser_download_url"] as? String else { return nil }
            return URL(string: s)
        }
        guard let url = asset(".dmg") ?? asset(".zip") else { return nil }
        return Release(tag: tag, name: (first["name"] as? String) ?? tag, assetURL: url)
    }

    /// Compare version tags like "v0.2-beta": numeric parts first, then prerelease
    /// rank (alpha < beta < rc < release). Compared against CFBundleShortVersionString,
    /// which the build sets to the tag's version (e.g. "0.1-beta").
    func isNewer(_ latest: String, than current: String) -> Bool {
        key(current).lexicographicallyPrecedes(key(latest))
    }

    private func key(_ tag: String) -> [Int] {
        var s = tag.lowercased()
        if s.hasPrefix("v") { s.removeFirst() }
        let rank = s.contains("alpha") ? 0 : s.contains("beta") ? 1 : (s.contains("rc") ? 2 : 3)
        let main = s.split(separator: "-").first.map(String.init) ?? s
        var nums = main.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        while nums.count < 3 { nums.append(0) }
        return Array(nums.prefix(3)) + [rank]
    }

    // MARK: - Prompt

    private func presentUpdate(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "A New Version of SideStep Is Available"
        a.informativeText = "SideStep \(release.tag) is available — you have \(currentVersion).\n\n"
            + "Click Update to download it and relaunch into the new version."
        a.addButton(withTitle: "Update")   // OK
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            Task { await downloadAndApply(release) }
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    // MARK: - Download & apply

    private func downloadAndApply(_ release: Release) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        let bundlePath = Bundle.main.bundlePath
        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            alert("Can’t Update Automatically",
                  "SideStep is in a read-only location. Opening the Releases page so you can download the update manually.")
            NSWorkspace.shared.open(releasesPage)
            return
        }

        let assetURL = release.assetURL
        let teamID = self.teamID
        let newApp: String? = await Task.detached(priority: .userInitiated) {
            await Self.prepare(assetURL: assetURL, requiredTeamID: teamID)
        }.value

        guard let newApp else {
            alert("Update Failed",
                  "The update couldn’t be downloaded or verified. Opening the Releases page instead.")
            NSWorkspace.shared.open(releasesPage)
            return
        }
        launchUpdaterAndQuit(newApp: newApp, dest: bundlePath)
    }

    /// Download the asset, extract SideStep.app (from a .dmg or .zip), and confirm it
    /// is notarized and signed by our team. Returns the path to the verified .app.
    private static func prepare(assetURL: URL, requiredTeamID: String) async -> String? {
        let fm = FileManager.default
        let work = NSTemporaryDirectory() + "sidestep-update-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)

        let isDMG = assetURL.pathExtension.lowercased() == "dmg"
        let assetPath = work + "/asset." + (isDMG ? "dmg" : "zip")
        // Self-update runs without a live progress window, so there's nowhere to show a
        // bar here — but route through the shared helper for consistent HTTP handling.
        guard (try? await Sideloader.downloadFile(from: assetURL, to: URL(fileURLWithPath: assetPath),
                                                  onProgress: { _, _ in })) != nil else { return nil }

        let extractDir = work + "/x"
        try? fm.createDirectory(atPath: extractDir, withIntermediateDirectories: true)
        var appPath: String?

        if isDMG {
            // Mount, copy the .app out, unmount — never verify/run from the mount.
            let mnt = work + "/mnt"
            _ = await runTool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-quiet", "-mountpoint", mnt, assetPath])
            if let appName = (try? fm.contentsOfDirectory(atPath: mnt))?.first(where: { $0.hasSuffix(".app") }) {
                let dest = extractDir + "/" + appName
                _ = await runTool("/usr/bin/ditto", [mnt + "/" + appName, dest])
                appPath = dest
            }
            _ = await runTool("/usr/bin/hdiutil", ["detach", "-quiet", mnt])
        } else {
            _ = await runTool("/usr/bin/ditto", ["-x", "-k", assetPath, extractDir])
            if let appName = (try? fm.contentsOfDirectory(atPath: extractDir))?.first(where: { $0.hasSuffix(".app") }) {
                appPath = extractDir + "/" + appName
            }
        }
        guard let appPath, fm.fileExists(atPath: appPath) else { return nil }

        // Must be accepted by Gatekeeper (i.e. notarized) …
        let assess = await runTool("/usr/sbin/spctl", ["--assess", "--type", "exec", "-v", appPath])
        guard assess.lowercased().contains("accepted") else { return nil }
        // … and signed by the expected Developer ID team.
        let cs = await runTool("/usr/bin/codesign", ["-dv", "--verbose=4", appPath])
        guard cs.contains("TeamIdentifier=\(requiredTeamID)") else { return nil }

        return appPath
    }

    /// Minimal process runner — combined stdout+stderr. Self-contained so this file
    /// can be dropped into any app.
    private static func runTool(_ path: String, _ args: [String]) async -> String {
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
            } catch {
                cont.resume(returning: "")
            }
        }
    }

    private func launchUpdaterAndQuit(newApp: String, dest: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        NEWAPP="\(newApp)"
        DEST="\(dest)"
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        /usr/bin/ditto "$NEWAPP" "$DEST.updating" || exit 1
        /bin/rm -rf "$DEST"
        /bin/mv "$DEST.updating" "$DEST"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        /usr/bin/open "$DEST"
        """
        let scriptPath = NSTemporaryDirectory() + "sidestep-update-\(pid).sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [scriptPath]
            try p.run()                 // detached; keeps running after we quit
            NSApp.terminate(nil)
        } catch {
            alert("Update Failed", "Couldn’t start the updater: \(error.localizedDescription)")
        }
    }
}
