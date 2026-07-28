// In-app debug log: captures everything written to stdout/stderr (prints, NSLog,
// AltSign logging, the install pipeline) into a live, on-screen, savable window.
// Opened from the menu so a tester on another Mac can reproduce a failure and
// send back the full log.
import SwiftUI
import AppKit
import Darwin

// Crash-safe log at a fixed path, opened first thing and written with raw,
// unbuffered write() calls — so it survives an immediate exit / crash on launch
// (when the on-screen Debug Log window never gets a chance to appear). Signal +
// uncaught-exception handlers record hard crashes with a backtrace.
enum CrashLog {
    static let path = "/tmp/isideload.log"
    static let fd: Int32 = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    // Pre-allocated so the signal handler never calls malloc.
    static var backtraceBuf = [UnsafeMutableRawPointer?](repeating: nil, count: 128)

    static func raw(_ s: String) {
        guard fd >= 0 else { return }
        var b = Array(s.utf8)
        _ = b.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
    static func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        raw("[\(f.string(from: Date()))] \(s)\n")
    }
    static func bootstrap() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        raw("\n==== iSideload \(v) launch \(Date()) pid \(getpid()) ====\n")
        raw("macOS \(ProcessInfo.processInfo.operatingSystemVersionString); bundle \(Bundle.main.bundleURL.path)\n")
        NSSetUncaughtExceptionHandler { ex in
            CrashLog.raw("\n!!!! UNCAUGHT EXCEPTION \(ex.name.rawValue): \(ex.reason ?? "")\n")
            for line in ex.callStackSymbols { CrashLog.raw(line + "\n") }
        }
        for s in [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGTRAP, SIGFPE] { signal(s, crashSignalHandler) }
    }
}

private func writeStatic(_ fd: Int32, _ s: StaticString) {   // allocation-free, signal-safe
    s.withUTF8Buffer { write(fd, $0.baseAddress, $0.count) }
}
private func crashSignalHandler(_ sig: Int32) {
    let fd = CrashLog.fd
    writeStatic(fd, "\n!!!! iSideload FATAL SIGNAL ")
    switch sig {
    case SIGSEGV: writeStatic(fd, "SIGSEGV")
    case SIGABRT: writeStatic(fd, "SIGABRT")
    case SIGILL:  writeStatic(fd, "SIGILL")
    case SIGBUS:  writeStatic(fd, "SIGBUS")
    case SIGTRAP: writeStatic(fd, "SIGTRAP")
    case SIGFPE:  writeStatic(fd, "SIGFPE")
    default:      writeStatic(fd, "?")
    }
    writeStatic(fd, " !!!!\n")
    let n = backtrace(&CrashLog.backtraceBuf, 128)
    backtrace_symbols_fd(CrashLog.backtraceBuf, n, fd)
    signal(sig, SIG_DFL); raise(sig)
}

final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var text = "(waiting for output…)\n"
    private let q = DispatchQueue(label: "com.decent.isideload.debuglog")
    private var buf = Data()

    /// Append raw captured bytes (from the stdout/stderr tap).
    func write(_ data: Data) {
        q.async {
            self.buf.append(data)
            if self.buf.count > 800_000 { self.buf.removeFirst(self.buf.count - 600_000) }
            let s = String(decoding: self.buf, as: UTF8.self)
            DispatchQueue.main.async { self.text = s }
        }
    }
    func clear() { q.async { self.buf.removeAll(); DispatchQueue.main.async { self.text = "" } } }
    var fullText: String { q.sync { String(decoding: buf, as: UTF8.self) } }
}

/// Timestamped log line → the crash-safe /tmp log AND (via print → stdout tap)
/// the on-screen window and ~/Library/Logs.
func dlog(_ s: String) {
    CrashLog.log(s)
    print(s)
}

struct DebugLogView: View {
    @ObservedObject var log = DebugLog.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("iSideload Debug Log").font(.headline)
                Spacer()
                Button("Save to file…") { save() }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.fullText, forType: .string)
                }
                Button("Clear") { log.clear() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: log.text) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
        .padding(12)
        .frame(minWidth: 700, minHeight: 460)
    }
    private func save() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "iSideload-debug.txt"
        p.allowedContentTypes = [.plainText]
        p.canCreateDirectories = true
        if p.runModal() == .OK, let url = p.url {
            try? log.fullText.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Single reusable debug-log window.
enum DebugWindow {
    private static var win: NSWindow?
    static func show() {
        if let w = win { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "iSideload Debug Log"
        w.contentViewController = NSHostingController(rootView: DebugLogView())
        w.isReleasedWhenClosed = false
        w.center()
        win = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
