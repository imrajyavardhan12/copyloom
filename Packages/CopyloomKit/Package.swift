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
        .executable(name: "copyloom-corpus", targets: ["CopyloomCorpusGenerator"]),
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
        .executableTarget(name: "CopyloomCorpusGenerator"),
        .testTarget(
            name: "ClipSearchTests",
            dependencies: ["ClipSearch"]
        ),
        .testTarget(
            name: "ClipStoreTests",
            dependencies: ["ClipDomain", "ClipStore"]
        ),
    ]
)
