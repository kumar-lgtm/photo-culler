// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ingest",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "Ingest",
            targets: ["Ingest"]
        ),
    ],
    dependencies: [
        .package(path: "../Catalog"),
        .package(path: "../Sidecar"),
        .package(path: "../Rename"),
    ],
    targets: [
        .target(
            name: "Ingest",
            dependencies: ["Catalog", "Sidecar", "Rename"]
        ),
    ]
)
