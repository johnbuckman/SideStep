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

/// Where hosted installer .zip downloads live (the web button's not-installed fallback).
let installerHostBase = "https://johnbuckman.github.io/SideStep/installers/"

@MainActor
final class Configurator: ObservableObject {
    enum Phase { case ask, done }
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
    @Published var madePath = ""

    /// Default the app name to the repo's last component until the user edits it.
    func repoChanged() {
        guard !appNameEdited else { return }
        if let r = RepoName.normalize(repoInput) { appName = RepoName.display(r) }
    }

    func create() {
        error = ""
        guard let repo = RepoName.normalize(repoInput) else {
            error = "Enter a GitHub repo as owner/name (e.g. johnbuckman/magnatune-app), or paste its github.com URL."
            return
        }
        let name = appName.trimmingCharacters(in: .whitespaces).isEmpty
            ? RepoName.display(repo) : appName.trimmingCharacters(in: .whitespaces)
        busy = true; status = "Looking up \(repo) on GitHub…"
        Task {
            guard let id = await GitHubID.idFor(repo) else {
                busy = false
                error = "Couldn’t find \(repo) on GitHub. Check the owner/name — and that the repo is public."
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
            madeRepo = repo; madeName = name; madeId = id; madePath = dst.path
            busy = false; phase = .done
        } catch {
            busy = false; self.error = "Couldn’t create the installer: \(error.localizedDescription)"
        }
    }

    var installerFilename: String { RepoName.installFilename(display: madeName, id: madeId) + ".app" }
    var installerDisplayName: String { RepoName.installFilename(display: madeName, id: madeId) } // Finder hides .app
    var installerZipURL: String {
        let file = installerFilename + ".zip"
        let enc = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return installerHostBase + enc
    }
    var html: String { WebSnippet.html(repo: madeRepo, installerURL: installerZipURL) }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: madePath)]) }
    func copyHTML() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(html, forType: .string) }
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
            case .ask:  ask
            case .done: done
            }
        }
        .frame(width: 620, height: 560)
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("SideStep Wizard", "shippingbox.fill")
            Text("Make a one-click installer for your iOS app.").font(.title3.weight(.medium))
            Text("Give it your GitHub repo — the one whose Releases contain your app’s .ipa. This builds a small installer you can send to anyone: it installs SideStep, gets their iPhone or iPad ready, and installs your app. It never bundles SideStep — it downloads the latest each time.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("GitHub repository").font(.callout.weight(.medium))
                TextField("owner/name  or  https://github.com/owner/name", text: $c.repoInput)
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

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Installer created", "checkmark.seal.fill")
            Text("**\(c.installerDisplayName)** is on your Desktop.").fixedSize(horizontal: false, vertical: true)
            Text("Send that file to anyone — opening it installs SideStep, readies their device, and installs \(c.madeName). Double-click it yourself to test.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Text("Add a one-click button to your website").font(.callout.weight(.semibold))
            Text("Paste this where you want the button. If a visitor already has SideStep it opens straight to your app; if not, it links them to your installer download.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(c.html).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Button("Reveal on Desktop") { c.revealInFinder() }
                Button("Test the Installer") { c.testInstaller() }
                Spacer()
                Button("Copy HTML") { c.copyHTML() }.keyboardShortcut(.defaultAction)
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

/// The website snippet. `installerURL` is the exact hosted .zip so the fallback download
/// works regardless of how the installer file is named.
enum WebSnippet {
    static func html(repo: String, installerURL: String) -> String {
        """
        <!-- Install with SideStep — one-click button for \(repo) -->
        <span class="sidestep-install"
              data-repo="\(repo)"
              data-installer="\(installerURL)"></span>
        <script>
        (function () {
          function mount(el){
            var repo=el.getAttribute("data-repo"); if(!repo) return;
            var dl=el.getAttribute("data-installer")||"";
            var app=el.getAttribute("data-app")||repo.split("/").pop();
            var btn=document.createElement("a");
            btn.textContent="Install "+app+" with SideStep";
            btn.href="sidestep://install?repo="+encodeURIComponent(repo);
            btn.style.cssText="display:inline-block;padding:12px 22px;border-radius:10px;background:#0a84ff;color:#fff;font-weight:600;text-decoration:none;cursor:pointer;";
            var note=document.createElement("div"); note.style.cssText="margin-top:10px;font-size:14px;opacity:.75;"; note.style.display="none";
            var downloaded=false;
            function download(){ if(!dl) return; var a=document.createElement("a"); a.href=dl; a.setAttribute("download",""); document.body.appendChild(a); a.click(); document.body.removeChild(a); }
            btn.addEventListener("click",function(){
              if(downloaded) return;
              btn.textContent="Installing\\u2026";
              var launched=false; function mark(){launched=true;}
              window.addEventListener("blur",mark,{once:true});
              document.addEventListener("visibilitychange",function vc(){if(document.hidden){launched=true;document.removeEventListener("visibilitychange",vc);}});
              setTimeout(function(){
                window.removeEventListener("blur",mark);
                if(launched) return;
                if(!dl){ note.textContent="Install SideStep first, then click again."; note.style.display="block"; return; }
                download();
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
