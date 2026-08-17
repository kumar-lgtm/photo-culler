// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "UI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UI", targets: ["UI"]),
    ],
    dependencies: [
        .package(path: "../Catalog"),
        .package(path: "../Decode"),
        .package(path: "../Sidecar"),
        .package(path: "../Rename"),
        .package(path: "../Shortcuts"),
        .package(path: "../Ingest")
    ],
    targets: [
        .target(
            name: "UI",
            dependencies: ["Catalog", "Decode", "Sidecar", "Rename", "Shortcuts", "Ingest"]
        ),
        .testTarget(
            name: "UITests",
            dependencies: ["UI"]
        ),
    ]
)
