// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "BotwireRunner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BotwireCore", targets: ["BotwireCore"]),
        .library(name: "BotwirePersistence", targets: ["BotwirePersistence"]),
        .library(name: "BotwireRuntime", targets: ["BotwireRuntime"]),
        .library(name: "BotwireRelay", targets: ["BotwireRelay"]),
        .executable(name: "botwire-runner", targets: ["botwire-runner"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.16.0"),
        .package(url: "https://github.com/parisxmas/OxiDB.git", branch: "master"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "4.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CJavaScriptCoreGTK",
            pkgConfig: "javascriptcoregtk-4.1",
            providers: [
                .apt(["libjavascriptcoregtk-4.1-dev"])
            ]
        ),
        .target(name: "BotwireCore"),
        .target(
            name: "BotwireShared",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(
            name: "BotwireTransferCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(
            name: "BotwirePersistence",
            dependencies: ["BotwireCore", .product(name: "OxiDB", package: "OxiDB")],
            linkerSettings: [
                .linkedLibrary("oxidb_embedded_ffi", .when(platforms: [.linux])),
                .linkedLibrary("bz2"),
                .linkedLibrary("lzma")
            ]
        ),
        .target(
            name: "BotwireRuntime",
            dependencies: [
                "BotwireCore",
                "BotwirePersistence",
                .target(name: "CJavaScriptCoreGTK", condition: .when(platforms: [.linux])),
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(
            name: "BotwireRelay",
            dependencies: [
                "BotwireCore",
                .product(name: "WebSocketKit", package: "websocket-kit")
            ]
        ),
        .executableTarget(
            name: "botwire-runner",
            dependencies: [
                "BotwireCore",
                "BotwirePersistence",
                "BotwireRuntime",
                "BotwireRelay",
                "BotwireShared",
                "BotwireTransferCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "BotwireRunnerTests",
            dependencies: ["BotwireCore", "BotwirePersistence", "BotwireRuntime", "BotwireRelay"]
        )
    ]
)
