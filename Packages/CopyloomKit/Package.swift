// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CopyloomKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ClipDomain", targets: ["ClipDomain"]),
        .library(name: "ClipSearch", targets: ["ClipSearch"]),
        .library(name: "ClipStore", targets: ["ClipStore"]),
        .library(name: "ClipboardCapture", targets: ["ClipboardCapture"]),
        .library(name: "QuickPasteFeature", targets: ["QuickPasteFeature"]),
        .executable(name: "copyloom-corpus", targets: ["CopyloomCorpusGenerator"]),
        .executable(name: "copyloom-bench", targets: ["CopyloomBenchmarks"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        )
    ],
    targets: [
        .target(name: "ClipDomain"),
        .target(name: "ClipSearch", dependencies: ["ClipDomain"]),
        .target(
            name: "ClipStore",
            dependencies: [
                "ClipDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(name: "ClipboardCapture", dependencies: ["ClipDomain"]),
        .target(name: "QuickPasteFeature", dependencies: ["ClipDomain", "ClipSearch"]),
        .executableTarget(name: "CopyloomCorpusGenerator"),
        .executableTarget(
            name: "CopyloomBenchmarks",
            dependencies: ["ClipDomain", "ClipSearch", "ClipStore", "ClipboardCapture"]
        ),
        .testTarget(
            name: "ClipSearchTests",
            dependencies: ["ClipSearch"]
        ),
        .testTarget(
            name: "ClipStoreTests",
            dependencies: [
                "ClipDomain",
                "ClipStore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "ClipboardCaptureTests",
            dependencies: ["ClipDomain", "ClipboardCapture", "ClipStore"]
        ),
        .testTarget(
            name: "QuickPasteFeatureTests",
            dependencies: ["ClipDomain", "QuickPasteFeature"]
        ),
    ]
)
