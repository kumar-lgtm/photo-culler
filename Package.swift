// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoCuller",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PhotoCuller", targets: ["PhotoCuller"]),
        // Headless regression suite — see Tests/Harness. Built as an executable rather than
        // an XCTest bundle so it runs without a full Xcode install (`swift run pcqa`).
        .executable(name: "pcqa", targets: ["pcqa"])
    ],
    dependencies: [
        .package(path: "Packages/Catalog"),
        .package(path: "Packages/Decode"),
        .package(path: "Packages/Sidecar"),
        .package(path: "Packages/Rename"),
        .package(path: "Packages/Shortcuts"),
        .package(path: "Packages/Ingest"),
        .package(path: "Packages/UI")
    ],
    targets: [
        .executableTarget(
            name: "PhotoCuller",
            dependencies: [
                "Catalog",
                "Decode",
                "Sidecar",
                "Rename",
                "Shortcuts",
                "Ingest",
                "UI"
            ],
            path: "PhotoCuller",
            exclude: ["Info.plist", "AppIcon.icns"]
        ),
        .executableTarget(
            name: "pcqa",
            dependencies: [
                "Catalog",
                "Decode",
                "Sidecar",
                "Rename",
                "Ingest",
                // UI is included so WorkspaceViewModel can be driven headlessly. SwiftUI
                // *views* still need a running app, but the state machine behind them —
                // filtering, auto-advance, folder switching, metadata commits — does not.
                "UI"
            ],
            path: "Tests/Harness"
        )
    ]
)
