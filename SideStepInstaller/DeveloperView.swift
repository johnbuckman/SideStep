//
//  DeveloperView — what SideStepWizard shows when run as itself (not yet renamed).
//
//  The developer enters their GitHub repo; the wizard looks up its immutable numeric
//  GitHub id and copies THIS app to "~/Desktop/<app> installer (<base62 id>)". That copy
//  is a plain rename (signature + notarization preserved), and the id in the filename is
//  how the installer finds the repo at run time — no URL shortener, and it survives repo
//  renames. We also hand over ready-to-paste website HTML.
//

import SwiftUI
import AppKit

@MainActor
final class Configurator: ObservableObject {
    enum Phase { case ask, host, snippet }
    @Published var phase: Phase = .ask
    @Published var repoInput = ""
    @Published var appName = ""
    @Published var appNameEdited = false
    @Published var busy = false
    @Published var status = ""
    @Published var error = ""

    @Published var madeRepo = ""
    @Published var madeName = ""
    @Published var madeId = 0
    @Published var madePath = ""      // the .app on the Desktop
    @Published var madeZipPath = ""   // the .zip of that .app, alongside it (for web hosting)
    /// Where the developer will host the installer .zip — the web button's fallback download.
    /// The developer fills this in on the result screen; it becomes the clearly-marked
    /// INSTALLER_URL variable at the top of the generated HTML.
    @Published var installerURL = ""
    @Published var copied = false     // set once "Copy HTML" is clicked, to confirm on screen

    init() { loadSettings() }

    // Persist what the developer last entered — reruns usually tweak one small thing, so
    // restoring the repo URL, app name, and hosting URL saves them re-typing it all.
    private enum Keys { static let repo = "wizard.repoURL", name = "wizard.appName", host = "wizard.hostURL" }
    private func loadSettings() {
        let d = UserDefaults.standard
        repoInput   = d.string(forKey: Keys.repo) ?? ""
        appName     = d.string(forKey: Keys.name) ?? ""
        installerURL = d.string(forKey: Keys.host) ?? ""
        if !appName.isEmpty { appNameEdited = true }   // don't let repoChanged() overwrite a restored name
    }
    func saveSettings() {
        let d = UserDefaults.standard
        d.set(repoInput, forKey: Keys.repo)
        d.set(appName, forKey: Keys.name)
        d.set(installerURL, forKey: Keys.host)
    }

    /// Default the app name to the repo's last component until the user edits it.
    func repoChanged() {
        guard !appNameEdited else { return }
        if let r = RepoName.normalize(repoInput) { appName = RepoName.display(r) }
    }

    func create() {
        error = ""
        guard let repo = RepoName.normalize(repoInput) else {
            error = "Enter your repo’s GitHub URL, e.g. https://github.com/owner/name."
            return
        }
        let name = appName.trimmingCharacters(in: .whitespaces).isEmpty
            ? RepoName.display(repo) : appName.trimmingCharacters(in: .whitespaces)
        saveSettings()   // remember these inputs for the next run
        busy = true; status = "Looking up \(repo) on GitHub…"
        Task {
            guard let id = await GitHubID.idFor(repo) else {
                busy = false
                error = "Couldn’t find that repo on GitHub. Check the URL — and that the repo is public."
                return
            }
            await buildInstaller(repo: repo, name: name, id: id)
        }
    }

    private func buildInstaller(repo: String, name: String, id: Int) async {
        status = "Building your installer…"
        let fm = FileManager.default
        guard let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            busy = false; error = "Couldn’t find your Desktop folder."; return
        }
        let dst = desktop.appendingPathComponent(RepoName.installFilename(display: name, id: id) + ".app")
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            // Byte copy of THIS bundle → keeps our Developer-ID signature + notarization;
            // only the filename differs. No re-sign.
            try fm.copyItem(at: Bundle.main.bundleURL, to: dst)
            var hide = URLResourceValues(); hide.hasHiddenExtension = true   // Finder shows "<app> installer (…)"
            var d = dst; try? d.setResourceValues(hide)

            // Also emit a .zip of the .app right next to it — a .app is a folder you can't link
            // to on the web, so this is the file the developer hosts for the button's fallback
            // download. ditto's PKZip keeps the bundle intact AND preserves the stapled
            // notarization ticket, so the unzipped installer still verifies offline. (Plain
            // `zip` would mangle the bundle's symlinks / extended attributes.)
            // Emit the .zip under a provisional "<name> installer.zip"; it's renamed to match the
            // filename in the hosting URL when the developer moves on (syncZipNameToURL). The id
            // only needs to live on the .app bundle INSIDE the zip (which keeps its real name).
            let zip = desktop.appendingPathComponent("\(name) installer.zip")
            if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
            try Self.ditto(zip: zip, of: dst)

            madeRepo = repo; madeName = name; madeId = id; madePath = dst.path; madeZipPath = zip.path
            // Keep whatever hosting URL was restored/entered (don't clear it) so a rerun doesn't
            // make the developer re-type it.
            copied = false
            busy = false; phase = .host
        } catch {
            busy = false; self.error = "Couldn’t create the installer: \(error.localizedDescription)"
        }
    }

    var installerFilename: String { RepoName.installFilename(display: madeName, id: madeId) + ".app" }
    var installerDisplayName: String { RepoName.installFilename(display: madeName, id: madeId) } // Finder hides .app
    /// The hosted .zip's filename — the filename part of the hosting URL the developer entered,
    /// so the file on disk matches their link exactly. Falls back to "<name> installer.zip"
    /// before a URL is entered.
    var installerZipName: String {
        let u = installerURL.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty {
            var s = u
            if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }  // drop query/fragment
            if let tail = s.split(separator: "/").last.map(String.init), !tail.isEmpty {
                return tail.removingPercentEncoding ?? tail
            }
        }
        return "\(madeName) installer.zip"
    }
    /// Suggested fallback URL: the installer .zip as a "latest release" asset on the app's own
    /// GitHub repo — where a developer naturally uploads it. Just a default; the developer can change it.
    var defaultInstallerURL: String {
        let file = "\(madeName) installer.zip"
        let enc = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return "https://github.com/\(madeRepo)/releases/latest/download/\(enc)"
    }
    /// Rename the Desktop .zip so its filename matches the hosting URL's filename part.
    func syncZipNameToURL() {
        guard !madeZipPath.isEmpty else { return }
        let fm = FileManager.default
        let src = URL(fileURLWithPath: madeZipPath)
        let target = src.deletingLastPathComponent().appendingPathComponent(installerZipName)
        guard target.lastPathComponent != src.lastPathComponent else { return }   // already matches
        do {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: src, to: target)
            madeZipPath = target.path
        } catch { /* non-fatal — keep the existing zip */ }
    }
    var html: String { WebSnippet.html(repo: madeRepo, name: madeName, installerURL: installerURL) }

    func revealInFinder() {
        syncZipNameToURL()   // make the revealed .zip already match the hosting link's filename
        var urls = [URL(fileURLWithPath: madePath)]
        if !madeZipPath.isEmpty { urls.append(URL(fileURLWithPath: madeZipPath)) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)   // selects both the .app and the .zip
    }
    func copyHTML() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(html, forType: .string)
        copied = true
    }

    /// Zip an .app bundle with ditto (PKZip; preserves the bundle + its stapled notarization).
    private static func ditto(zip: URL, of app: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path]
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "SideStepWizard", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn’t zip the installer (ditto exited \(p.terminationStatus))."])
        }
    }
    func testInstaller() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true; cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: madePath), configuration: cfg, completionHandler: nil)
    }
}

struct DeveloperView: View {
    @StateObject private var c = Configurator()
    var body: some View {
        Group {
            switch c.phase {
            case .ask:     ask
            case .host:    host
            case .snippet: snippet
            }
        }
        .frame(width: 620, height: 620)
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("SideStep Wizard", "shippingbox.fill")
            Text("Make a one-click installer for your iOS app.").font(.title3.weight(.medium))
            Text("Give it your GitHub repo — the one whose Releases contain your app’s .ipa. This builds a small installer you can send to anyone: it installs SideStep, gets their iPhone or iPad ready, and installs your app. It never bundles SideStep — it downloads the latest each time.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("GitHub repository URL").font(.callout.weight(.medium))
                TextField("https://github.com/owner/name", text: $c.repoInput)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: c.repoInput) { _ in c.repoChanged() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("App name").font(.callout.weight(.medium))
                TextField("shown in the installer’s name", text: $c.appName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: c.appName) { _ in c.appNameEdited = true }
                Text("The installer is named “\(c.appName.isEmpty ? "app" : c.appName) installer (…)”. The code in parentheses is your repo’s GitHub id — how the installer finds your app, reliably, even if you later rename the repo.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if !c.error.isEmpty {
                Text(c.error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 10) {
                if c.busy { ProgressView().scaleEffect(0.7).frame(width: 16, height: 16); Text(c.status).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Create Installer") { c.create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(c.busy || c.repoInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28)
    }

    // Step 1 of the result flow: the installer file is made — ask where it'll be hosted.
    private var host: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Installer created", "checkmark.seal.fill")
            Text("**\(c.installerDisplayName)** is on your Desktop, along with **\(c.installerZipName)**.").fixedSize(horizontal: false, vertical: true)
            Text("Send the .app to anyone — opening it installs SideStep, readies their device, and installs \(c.madeName). Double-click it yourself to test. The .zip is the same installer, ready to host on the web (below).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Where will you host the installer?").font(.callout.weight(.medium))
                TextField("https://…/\(c.installerZipName)", text: $c.installerURL)
                    .textFieldStyle(.roundedBorder)
                Text("Paste the public link where you'll host the installer — it's the download visitors get if they don't already have SideStep. Your Desktop **.zip is renamed to match its filename** (**\(c.installerZipName)**). A common choice is your repo's latest GitHub release: \(c.defaultInstallerURL)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }

            Spacer()
            HStack {
                Button("Back") { c.phase = .ask }
                Button("Reveal on Desktop") { c.revealInFinder() }
                Button("Test the Installer") { c.testInstaller() }
                Spacer()
                Button("Next: Website Button") { c.syncZipNameToURL(); c.saveSettings(); c.copied = false; c.phase = .snippet }
                    .keyboardShortcut(.defaultAction)
                    .disabled(c.installerURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28)
    }

    // Step 2 of the result flow: show the ready-to-paste website button HTML.
    private var snippet: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Add a one-click button", "chevron.left.forwardslash.chevron.right")
            Text("Paste this where you want the button. If a visitor already has SideStep it opens straight to \(c.madeName); if not, it links them to the installer download you set. The link — and the button's styling — are clearly-marked variables at the top of the snippet, so you can change them anytime.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(c.html).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Button("Back") { c.phase = .host }
                Spacer()
                Button("Copy HTML") { c.copyHTML() }.keyboardShortcut(.defaultAction)
                Button("Done") { NSApplication.shared.terminate(nil) }
            }
            if c.copied {
                HStack {
                    Spacer()
                    Label("Copied to clipboard", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
        }
        .padding(28)
    }

    private func header(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tint)
            Text(title).font(.title.bold())
        }
    }
}

/// The website snippet. `installerURL` is the hosted .zip the button downloads when the
/// visitor doesn't have SideStep — surfaced as a clearly-marked `INSTALLER_URL` variable at
/// the top of the script so it's trivial to change. `name` is the developer-typed app name,
/// carried in `data-app` so the button reads "Install <Name>…" with the exact casing they
/// entered (not the lowercase repo tail).
enum WebSnippet {
    /// Escape a value for use inside a double-quoted HTML attribute.
    private static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escape a value for use inside a double-quoted JavaScript string literal.
    private static func js(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func html(repo: String, name: String, installerURL: String) -> String {
        """
        <!-- Install \(name) with SideStep — one-click button for \(repo) -->
        <span class="sidestep-install"
              data-repo="\(attr(repo))"
              data-app="\(attr(name))"></span>
        <script>
        // ══════════════════════════════════════════════════════════════════════════
        //  SETTINGS — edit these three lines to fit your site.
        // ══════════════════════════════════════════════════════════════════════════

        // The link visitors download if they don't already have SideStep.
        // Point it at wherever you host your "\(name) installer" .zip file.
        var INSTALLER_URL = "\(js(installerURL))";

        // To make this button match your site's own buttons, set BUTTON_CLASS to their
        // CSS class — e.g. "button special small" — and your stylesheet styles it. Leave
        // BUTTON_CLASS empty ("") to use the inline BUTTON_STYLE below instead.
        var BUTTON_CLASS = "";
        var BUTTON_STYLE = "display:inline-block;padding:12px 22px;border-radius:10px;background:#0a84ff;color:#fff;font-weight:600;text-decoration:none;cursor:pointer;";
        // ══════════════════════════════════════════════════════════════════════════

        (function () {
          function mount(el){
            var repo=el.getAttribute("data-repo"); if(!repo) return;
            var dl=el.getAttribute("data-installer")||INSTALLER_URL||"";
            var app=el.getAttribute("data-app")||repo.split("/").pop();
            var btn=document.createElement("a");
            btn.textContent="Install "+app+" with SideStep";
            btn.href="sidestep://install?repo="+encodeURIComponent(repo);
            if(BUTTON_CLASS) btn.className=BUTTON_CLASS; else btn.style.cssText=BUTTON_STYLE;
            var note=document.createElement("div"); note.style.cssText="margin-top:10px;font-size:14px;opacity:.75;"; note.style.display="none";
            // SideStep is a Mac app that sideloads onto an iPhone/iPad over USB; both the
            // sidestep:// hand-off and the .app installer are useless off a Mac. So if this
            // page isn't on a Mac, show why instead of firing a link that silently does nothing.
            // iPadOS Safari masquerades as a Mac (UA "Macintosh", platform "MacIntel"), so a
            // REAL Mac is Mac-like AND non-touch; an iPad is Mac-like WITH touch (maxTouchPoints>1).
            var macLike=/Mac/.test(navigator.platform||navigator.userAgent||"");
            var touch=(navigator.maxTouchPoints||0)>1;
            if(!(macLike&&!touch)){
              var onApple=/iPhone|iPad|iPod/.test(navigator.userAgent||"")||(macLike&&touch);
              btn.removeAttribute("href");
              if(!BUTTON_CLASS) btn.style.cssText=BUTTON_STYLE+"background:#8e8e93;cursor:default;";
              btn.style.pointerEvents="none"; btn.setAttribute("aria-disabled","true");
              // A site BUTTON_CLASS can be a fixed-height pill (line-height≈45px, overflow:hidden,
              // white-space:nowrap) that CLIPS a 2nd line — relax those so the warning below shows.
              btn.style.height="auto"; btn.style.lineHeight="1.3"; btn.style.overflow="visible"; btn.style.whiteSpace="normal"; btn.style.paddingTop="10px"; btn.style.paddingBottom="10px";
              // "⚠️ Must be run on a Mac" is a 2nd line of text INSIDE the disabled button.
              var warn=document.createElement("span"); warn.textContent="\u{26A0}\u{FE0F} Must be run on a Mac"; warn.style.cssText="display:block;font-size:.85em;font-weight:600;margin-top:2px;"; btn.appendChild(warn);
              note.textContent=onApple
                ? "SideStep installs "+app+" onto your iPhone or iPad from a Mac. Open this page on a Mac, then plug this device in with a USB cable."
                : "SideStep runs on a Mac. Open this page on a Mac to install "+app+".";
              note.style.display="block";
              el.appendChild(btn); el.appendChild(note); return;
            }
            var downloaded=false;
            function download(){ if(!dl) return; var a=document.createElement("a"); a.href=dl; a.setAttribute("download",""); document.body.appendChild(a); a.click(); document.body.removeChild(a); }
            btn.addEventListener("click",function(ev){
              if(downloaded) return;                        // 2nd click: button now points at the installer — let it download
              ev.preventDefault();                          // launch the app ourselves; letting the <a href="sidestep://"> navigate is what pops Safari's "address is invalid" dialog
              btn.textContent="Installing\\u2026";
              // If SideStep launches, the browser backgrounds this page and it becomes hidden.
              // We key off document.hidden ONLY — not window "blur", which also fires when the
              // browser shows a "scheme has no registered handler" alert, causing us to wrongly
              // conclude SideStep opened and skip the installer download.
              var launched=false;
              document.addEventListener("visibilitychange",function vc(){if(document.hidden){launched=true;document.removeEventListener("visibilitychange",vc);}});
              var scheme="sidestep://install?repo="+encodeURIComponent(repo);
              // Safari pops a blocking "address is invalid" dialog when a custom scheme has no
              // handler and you navigate the TOP window — but NOT inside a hidden iframe, where a
              // missing handler fails silently. Other browsers block iframe scheme-launches, so
              // navigate the window there (they show no blocking dialog when the handler's absent).
              var isSafari=/^((?!chrome|chromium|android|crios|fxios|edg).)*safari/i.test(navigator.userAgent)&&/apple/i.test(navigator.vendor||"");
              if(isSafari){
                var ifr=document.createElement("iframe"); ifr.style.display="none"; ifr.src=scheme;
                document.body.appendChild(ifr);
                setTimeout(function(){ if(ifr.parentNode) ifr.parentNode.removeChild(ifr); },1000);
              } else { window.location.href=scheme; }
              setTimeout(function(){
                if(launched) return;                        // SideStep opened → nothing to do
                if(!dl){ note.textContent="Install SideStep first, then click again."; note.style.display="block"; btn.textContent="Install "+app+" with SideStep"; return; }
                download();                                  // SideStep isn't installed → fetch the installer
                downloaded=true; btn.href=dl; btn.setAttribute("download","");
                btn.textContent="Run the "+app+" installer now";
                note.textContent="It\\u2019s going to your Downloads folder now.";
                note.style.display="block";
              },1500);
            });
            el.appendChild(btn); el.appendChild(note);
          }
          function init(){document.querySelectorAll(".sidestep-install").forEach(mount);}
          if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",init); else init();
        })();
        </script>
        """
    }
}
