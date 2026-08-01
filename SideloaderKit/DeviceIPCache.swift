// Remembers each device's last-known LAN IP, learned from its Wi-Fi beacon.
// A manual "Refresh" has no beacon to hand over the IP and a Wi-Fi-only device
// often isn't in usbmuxd's list, so without this a manual refresh of an unplugged
// device fails with "no device". With it, we can reach the device by direct IP.
import Foundation

public enum DeviceIPCache {
    static let path = SideStepSupportDir + "/device-ips.json"

    private static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }
    private static func save(_ m: [String: String]) {
        try? FileManager.default.createDirectory(atPath: SideStepSupportDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: URL(fileURLWithPath: path)) }
    }

    /// Record a device's current IP (from its beacon). No-op if unchanged.
    public static func remember(_ udid: String, ip: String) {
        guard !udid.isEmpty, !ip.isEmpty else { return }
        var m = load()
        if m[udid] == ip { return }
        m[udid] = ip
        save(m)
    }

    /// Last-known IP for a device, if any.
    public static func ip(for udid: String) -> String? {
        let v = load()[udid]
        return (v?.isEmpty == false) ? v : nil
    }
}
