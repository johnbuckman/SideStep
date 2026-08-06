//
//  WizardView — the step-by-step UI. Each device-dependent step advances on its own
//  the instant a real check (device present, trusted, Developer Mode on) passes.
//

import SwiftUI

struct WizardView: View {
    @ObservedObject var w: Wizard

    var body: some View {
        VStack(spacing: 0) {
            WizStepRail(current: w.step)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
        }
        .frame(width: 560, height: 420)
    }

    @ViewBuilder private var content: some View {
        switch w.step {
        case .welcome:    welcome
        case .installApp: installApp
        case .connect:    connect
        case .trust:      trust
        case .devMode:    devMode
        case .ready:      ready
        }
    }

    private var welcome: some View {
        WizBody(icon: "shippingbox.fill",
                title: "Install \(w.repoDisplay)",
                blurb: "This will install SideStep on your Mac, help you get your iPhone or iPad ready, and then install \(w.repoDisplay) on your device. It only takes a minute.") {
            HStack {
                Spacer()
                Button("Get Started") { w.begin() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var installApp: some View {
        WizBody(icon: "arrow.down.circle.fill",
                title: "Getting SideStep",
                blurb: "Downloading the latest SideStep and installing it into your Applications folder.") {
            VStack(alignment: .leading, spacing: 12) {
                WizStatus(text: w.detail, busy: w.busy, ok: !w.failed)
                if w.failed {
                    HStack {
                        Spacer()
                        Button("Open Releases Page") { NSWorkspace.shared.open(Downloader.releasesPage) }
                        Button("Try Again") { w.runDownloadInstall() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    private var connect: some View {
        WizBody(icon: "cable.connector",
                title: "Plug in your device",
                blurb: "Connect your iPhone or iPad to this Mac with a USB cable. If a “Trust This Computer?” prompt appears, you’ll handle it on the next step.") {
            WizStatus(text: w.detail.isEmpty ? "Waiting for a device on USB…" : w.detail, busy: true, ok: true)
        }
    }

    private var trust: some View {
        WizBody(icon: "lock.shield.fill",
                title: "Trust this computer",
                blurb: "On the device, tap “Trust” when asked and enter its passcode. Keep it unlocked.") {
            WizStatus(text: w.detail.isEmpty ? "Waiting for you to tap Trust…" : w.detail, busy: true, ok: true)
        }
    }

    private var devMode: some View {
        WizBody(icon: "hammer.fill",
                title: "Turn on Developer Mode",
                blurb: "iOS 16 and later need Developer Mode to install apps this way. SideStep can switch it on for you; if your device has a passcode, you’ll flip one switch in Settings and it will restart.") {
            VStack(alignment: .leading, spacing: 12) {
                WizStatus(text: w.detail.isEmpty ? "Checking Developer Mode…" : w.detail, busy: w.busy, ok: true)
                if w.devModeNeedsManual {
                    Text(DeviceTool.developerModeHelp).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Turn On Developer Mode") { w.enableDeveloperMode() }
                        .disabled(w.busy || w.device == nil)
                }
            }
        }
    }

    private var ready: some View {
        WizBody(icon: "checkmark.seal.fill",
                title: "Your device is ready",
                blurb: "Everything’s set up. SideStep will now install \(w.repoDisplay). After it installs, go to Settings ▸ General ▸ VPN & Device Management to trust the developer.") {
            HStack { Spacer(); Button("Install \(w.repoDisplay)") { w.handOff() }.keyboardShortcut(.defaultAction) }
        }
    }
}

private struct WizStepRail: View {
    let current: WizardStep
    private let labels: [(WizardStep, String)] = [
        (.welcome, "Start"), (.installApp, "SideStep"), (.connect, "Connect"),
        (.trust, "Trust"), (.devMode, "Dev Mode"), (.ready, "Install")
    ]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, item in
                let done = item.0.rawValue < current.rawValue
                let active = item.0 == current
                VStack(spacing: 4) {
                    Circle().fill(done || active ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 10, height: 10)
                    Text(item.1).font(.caption2).foregroundStyle(active ? .primary : .secondary)
                        .lineLimit(1).fixedSize()
                }
                if i < labels.count - 1 {
                    Rectangle().fill(done ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 2).frame(maxWidth: .infinity).offset(y: -8)
                }
            }
        }
    }
}

private struct WizBody<Footer: View>: View {
    let icon: String; let title: String; let blurb: String
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tint).frame(width: 44)
                Text(title).font(.title2.bold())
            }
            Text(blurb).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WizStatus: View {
    let text: String; let busy: Bool; let ok: Bool
    var body: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().scaleEffect(0.7).frame(width: 16, height: 16) }
            else { Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange) }
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
