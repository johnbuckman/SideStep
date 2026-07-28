// Same-account-on-two-Macs guard. Before SideStep accepts a login, it broadcasts a
// hashed "claim" for that Apple ID on the LAN; any other running SideStep that holds
// the same account answers, and the new Mac refuses the login. This stops two Macs
// managing the same account (which races on pushes and burns Apple's per-account
// limits twice as fast). Only the *hash* of the Apple ID travels the wire.
import Foundation
import CryptoKit
import Darwin

public enum LANLock {
    public static let instanceID = UUID().uuidString      // unique per app launch
    public static let port: UInt16 = BeaconListener.port  // shares the beacon UDP port

    public static func hash(_ appleID: String) -> String {
        let d = Data(appleID.lowercased().trimmingCharacters(in: .whitespaces).utf8)
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }
    public static func hostName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// If another SideStep on the LAN is logged in with `appleID`, returns that Mac's
    /// name; nil means it's free to use here. ~`timeout`s round-trip.
    public static func ownerOnNetwork(appleID: String, timeout: TimeInterval = 1.5) async -> String? {
        await Task.detached(priority: .userInitiated) { blockingCheck(appleID, timeout) }.value
    }

    /// A listener should answer a claim only if it's from a DIFFERENT instance and it
    /// holds an account whose hash matches.
    public static func shouldAnswer(instanceID other: String, hash h: String) -> Bool {
        other != instanceID && AccountStore.appleIDs.contains { hash($0) == h }
    }

    private static func blockingCheck(_ appleID: String, _ timeout: TimeInterval) -> String? {
        let s = socket(AF_INET, SOCK_DGRAM, 0); if s < 0 { return nil }
        defer { close(s) }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000))
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // bind an ephemeral port so answers come back to us
        var me = sockaddr_in(); me.sin_family = sa_family_t(AF_INET); me.sin_addr.s_addr = INADDR_ANY; me.sin_port = 0
        _ = withUnsafePointer(to: &me) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }

        let msg = Array("SIDESTEP-CLAIM \(instanceID) \(hash(appleID))\n".utf8)
        for bcast in broadcastAddrs() {
            var dst = sockaddr_in(); dst.sin_family = sa_family_t(AF_INET); dst.sin_port = port.bigEndian
            inet_pton(AF_INET, bcast, &dst.sin_addr)
            _ = withUnsafePointer(to: &dst) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { dp in
                msg.withUnsafeBytes { sendto(s, $0.baseAddress, msg.count, 0, dp, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 512)
        while Date() < deadline {
            let n = recv(s, &buf, buf.count, 0)
            if n <= 0 { break }   // timeout / error
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            if text.hasPrefix("SIDESTEP-OWNED ") {
                let host = text.dropFirst("SIDESTEP-OWNED ".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return host.isEmpty ? "another Mac" : host
            }
        }
        return nil
    }

    /// 255.255.255.255 plus each interface's directed broadcast (more networks pass
    /// directed broadcast than the limited one).
    static func broadcastAddrs() -> [String] {
        var out = ["255.255.255.255"]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return out }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let cur = p {
            if let a = cur.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
               let m = cur.pointee.ifa_netmask {
                let addr = UnsafeRawPointer(a).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                let mask = UnsafeRawPointer(m).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                let bcast = addr | ~mask
                if bcast != 0, bcast != 0xffff_ffff {
                    var ba = in_addr(s_addr: bcast)
                    var cbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &ba, &cbuf, socklen_t(INET_ADDRSTRLEN))
                    let str = String(cString: cbuf)
                    if str != "127.255.255.255", !out.contains(str) { out.append(str) }
                }
            }
            p = cur.pointee.ifa_next
        }
        return out
    }
}
