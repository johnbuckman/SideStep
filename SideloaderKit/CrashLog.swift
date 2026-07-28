// Crash-safe log at a fixed path, opened first thing and written with raw,
// unbuffered write() calls — survives an immediate exit/crash on launch (before
// the on-screen Debug Log window could appear). Lives in SideloaderKit so the
// install pipeline + background daemons can log to it too. Signal + uncaught-
// exception handlers record hard crashes with a backtrace.
import Foundation
import Darwin

public enum CrashLog {
    public static let path = "/tmp/isideload.log"
    public static let fd: Int32 = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    public static var backtraceBuf = [UnsafeMutableRawPointer?](repeating: nil, count: 128)

    public static func raw(_ s: String) {
        guard fd >= 0 else { return }
        var b = Array(s.utf8)
        _ = b.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
    public static func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        raw("[\(f.string(from: Date()))] \(s)\n")
    }
    public static func bootstrap(version: String) {
        // Ignore SIGPIPE process-wide. installDiagnosticsLog() redirects stdout/
        // stderr through a pipe; if its read end stalls/closes, a write() to the
        // redirected fd would otherwise raise SIGPIPE and terminate the app right
        // after init (observed as EXIT=141 on some Macs). With SIG_IGN the write
        // just fails with EPIPE. Must run before any pipe I/O is set up.
        signal(SIGPIPE, SIG_IGN)
        raw("\n==== iSideload \(version) launch \(Date()) pid \(getpid()) ====\n")
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
