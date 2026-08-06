// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "AltSign",
    platforms: [
        .iOS(.v14),
        .macOS(.v14)   // bumped from v11 for the SwiftUI installer app (build host is macOS 26)
    ],

    products: [
        .library(
            name: "AltSign-Static",
            type: .static,
            targets: ["AltSign"]
        ),
        .library(
            name: "AltSign-Dynamic",
            type: .dynamic,
            targets: ["AltSign"]
        ),
        .library(
            name: "OpenSSL",
            targets: ["OpenSSL"]
        )
    ],


    targets: [
        .binaryTarget(
            name: "OpenSSL",
            url: "https://github.com/krzyzanowskim/OpenSSL/releases/download/3.6.2000/OpenSSL.xcframework.zip",
            checksum: "37846a8bd302cb2443eff47f1045ab844d0cd40bf82cc6159cfad9aa5c3eff9e"
        ),

        // ─────────────────────────
        // C / C++ bridge
        // ─────────────────────────
        .target(
            name: "NativeBridge",
            dependencies: [
                "OpenSSL"          // zsign's openssl.cpp links libcrypto/libssl
            ],
            path: ".",
            sources: [
                "NativeBridge/Sources",

                "Dependencies/minizip/ioapi.c",
                "Dependencies/minizip/mztools.c",
                "Dependencies/minizip/unzip.c",
                "Dependencies/minizip/zip.c",

                // zsign (SHA-256-primary signer) replaces rileytestut/ldid.
                // Folder-signing subset only: archive.cpp/certcheck.cpp/metadata.cpp
                // and zsign's vendored zlib/minizip are excluded (IPA-zip / -C / -x
                // paths we don't use), avoiding a minizip clash with Dependencies/minizip.
                "Dependencies/zsign/src/archo.cpp",
                "Dependencies/zsign/src/bundle.cpp",
                "Dependencies/zsign/src/macho.cpp",
                "Dependencies/zsign/src/openssl.cpp",
                "Dependencies/zsign/src/signing.cpp",
                "Dependencies/zsign/src/common/base64.cpp",
                "Dependencies/zsign/src/common/fs.cpp",
                "Dependencies/zsign/src/common/json.cpp",
                "Dependencies/zsign/src/common/log.cpp",
                "Dependencies/zsign/src/common/sha.cpp",
                "Dependencies/zsign/src/common/timer.cpp",
                "Dependencies/zsign/src/common/util.cpp",

                "Dependencies/corecrypto/Sources/ccsrp.m"
            ],

            publicHeadersPath: "NativeBridge/include",

            cSettings: [
                .headerSearchPath("Dependencies/minizip"),

                .headerSearchPath("Dependencies/corecrypto/include"),
                .headerSearchPath("Dependencies/corecrypto/include/corecrypto"),

                .define("unix", to: "1"),
                .define("CORECRYPTO_DONOT_USE_TRANSPARENT_UNION", to: "1"),
                .define("NOCRYPT"),
                .define("NOUNCRYPT"),

                .unsafeFlags(["-w"])
            ],

            cxxSettings: [
                .headerSearchPath("NativeBridge/include"),
                .headerSearchPath("Dependencies/corecrypto/include"),
                .headerSearchPath("Dependencies/zsign/src"),
                .headerSearchPath("Dependencies/zsign/src/common"),
                .unsafeFlags(["-w"])
            ],

            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("Security"),
            ]
        ),

        // ─────────────────────────
        // Swift-safe bridge
        // ─────────────────────────
        .target(
            name: "SwiftBridge",
            dependencies: ["NativeBridge", "OpenSSL"],
            path: "SwiftBridge",
            sources: [ "." ],
            linkerSettings: [
                .linkedFramework("CryptoKit"),      // AES-GCM, HMAC-SHA256, SHA256
            ]
        ),

       // ─────────────────────────
       // Main Swift target
       // ─────────────────────────
        .target(
            name: "AltSign",
            dependencies: ["SwiftBridge"],
            path: "Sources"
        ),

        // Local runtime proof of the Swift -> C -> zsign signing path (not shipped).
        .executableTarget(
            name: "ZsignTest",
            dependencies: ["SwiftBridge"],
            path: "ZsignTest"
        ),

        // Shared provisioning + signing + install pipeline (used by app + CLI).
        .target(
            name: "SideloaderKit",
            dependencies: ["AltSign", "SwiftBridge"],
            path: "SideloaderKit"
        ),

        // Apple-ID auth + provisioning CLI for the lean-AltServer Mac app.
        .executableTarget(
            name: "Provision",
            dependencies: ["AltSign", "SwiftBridge", "SideloaderKit"],
            path: "Provision"
        ),

        // iWish Installer — the macOS GUI app (SwiftUI).
        .executableTarget(
            name: "InstallerApp",
            dependencies: ["AltSign", "SwiftBridge", "SideloaderKit"],
            path: "InstallerApp"
        ),

        // Minimal standalone installer (distinct bundle id). No SideloaderKit/OpenSSL,
        // no embedded SideStep — it downloads the latest SideStep from GitHub releases,
        // readies the device using SideStep's own tools, then hands off via sidestep://.
        // Renamed "Install owner--repo.app" (its filename carries the repo).
        .executableTarget(
            name: "SideStepInstaller",
            path: "SideStepInstaller"
        )
    ],

    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .cxx14
)
