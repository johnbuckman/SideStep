// Extracts an installed app's icon for the UI. iOS app icons are almost always
// "CgBI" PNGs — Apple's iphone-optimized variant (raw DEFLATE, BGRA, premultiplied
// alpha) that ImageIO/NSImage can't read — so we decode those ourselves and cache a
// normal PNG. Anything unusual (icon only in Assets.car, odd pixel format) → no-op,
// and the UI falls back to its generic symbol.
import Foundation
import CoreGraphics
import ImageIO
import Compression
import UniformTypeIdentifiers

public enum AppIconCache {
    public static var dir: String { SideStepSupportDir + "/icons" }
    public static func path(bundleID: String) -> String {
        dir + "/" + bundleID.map { ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "_" }.map(String.init).joined() + ".png"
    }

    /// Best-effort: find the app's icon PNG, decode it, and cache a standard PNG.
    public static func extract(fromApp appPath: String, bundleID: String) {
        guard let src = iconFile(inApp: appPath), let cg = loadPNG(src) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let out = URL(fileURLWithPath: path(bundleID: bundleID))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: locate the largest AppIcon PNG in the bundle

    private static func fileSize(_ p: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int) ?? 0
    }
    private static func iconFile(inApp appPath: String) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let info = NSDictionary(contentsOfFile: appPath + "/Info.plist"),
           let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String], let base = files.last {
            for suffix in ["@3x.png", "@2x.png", ".png", "@2x~ipad.png", "~ipad.png"] {
                let p = appPath + "/" + base + suffix
                if fm.fileExists(atPath: p) { candidates.append(p) }
            }
        }
        if candidates.isEmpty, let items = try? fm.contentsOfDirectory(atPath: appPath) {
            for f in items where f.lowercased().hasSuffix(".png") && (f.hasPrefix("AppIcon") || f.hasPrefix("Icon")) {
                candidates.append(appPath + "/" + f)
            }
        }
        return candidates.max(by: { fileSize($0) < fileSize($1) })
    }

    // MARK: PNG loading (standard, then CgBI)

    private static func loadPNG(_ path: String) -> CGImage? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if !isCgBI(data), let s = CGImageSourceCreateWithData(data as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(s, 0, nil) { return img }
        return decodeCgBI(data)
    }

    private static func isCgBI(_ d: Data) -> Bool {
        // "CgBI" appears as a chunk type early in an iphone-optimized PNG.
        guard d.count > 16 else { return false }
        return d.prefix(64).range(of: Data("CgBI".utf8)) != nil
    }

    /// Decode an iphone-optimized (CgBI) 8-bit RGBA PNG → CGImage. Returns nil on
    /// any format we don't handle, so the caller falls back to the generic icon.
    private static func decodeCgBI(_ data: Data) -> CGImage? {
        let bytes = [UInt8](data)
        let sig: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count > 8, Array(bytes.prefix(8)) == sig else { return nil }

        var i = 8
        var width = 0, height = 0
        var idat = [UInt8]()
        func be32(_ o: Int) -> Int { (Int(bytes[o]) << 24) | (Int(bytes[o+1]) << 16) | (Int(bytes[o+2]) << 8) | Int(bytes[o+3]) }
        while i + 8 <= bytes.count {
            let len = be32(i)
            guard len >= 0, i + 12 + len <= bytes.count else { break }
            let type = String(bytes: bytes[i+4..<i+8], encoding: .ascii) ?? ""
            let dataStart = i + 8
            if type == "IHDR" {
                width = be32(dataStart); height = be32(dataStart + 4)
                let bitDepth = bytes[dataStart + 8], colorType = bytes[dataStart + 9], interlace = bytes[dataStart + 12]
                guard bitDepth == 8, colorType == 6, interlace == 0 else { return nil }   // 8-bit RGBA, non-interlaced only
            } else if type == "IDAT" {
                idat.append(contentsOf: bytes[dataStart..<dataStart+len])
            } else if type == "IEND" { break }
            i += 12 + len   // len + type(4) + data + crc(4)
        }
        guard width > 0, height > 0, width < 4096, height < 4096, !idat.isEmpty else { return nil }

        let stride = width * 4
        let expected = height * (stride + 1)   // one filter byte per row
        guard let raw = rawInflate(idat, expected: expected) else { return nil }

        // Un-filter scanlines (bpp = 4), then swap BGRA→RGBA (keep premultiplied alpha).
        var out = [UInt8](repeating: 0, count: height * stride)
        var prev = [UInt8](repeating: 0, count: stride)
        var cur = [UInt8](repeating: 0, count: stride)
        for row in 0..<height {
            let base = row * (stride + 1)
            let filter = raw[base]
            for x in 0..<stride {
                let rawv = raw[base + 1 + x]
                let a = x >= 4 ? cur[x - 4] : 0
                let b = prev[x]
                let c = x >= 4 ? prev[x - 4] : 0
                let add: UInt8
                switch filter {
                case 0: add = 0
                case 1: add = a
                case 2: add = b
                case 3: add = UInt8((Int(a) + Int(b)) / 2 & 0xFF)
                case 4: add = paeth(a, b, c)
                default: return nil
                }
                cur[x] = rawv &+ add
            }
            // BGRA (premultiplied) → RGBA (premultiplied)
            let o = row * stride
            var x = 0
            while x < stride {
                out[o + x]     = cur[x + 2]  // R ← B
                out[o + x + 1] = cur[x + 1]  // G
                out[o + x + 2] = cur[x]      // B ← R
                out[o + x + 3] = cur[x + 3]  // A
                x += 4
            }
            swap(&prev, &cur)
        }

        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    /// Raw DEFLATE inflate (CgBI IDAT has no zlib header). Apple's COMPRESSION_ZLIB
    /// is exactly raw DEFLATE.
    private static func rawInflate(_ input: [UInt8], expected: Int) -> [UInt8]? {
        var dst = [UInt8](repeating: 0, count: expected)
        let n = dst.withUnsafeMutableBufferPointer { d in
            input.withUnsafeBufferPointer { s in
                compression_decode_buffer(d.baseAddress!, expected, s.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == expected ? dst : nil
    }
}
