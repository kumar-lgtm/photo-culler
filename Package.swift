// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoCuller",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PhotoCuller", targets: ["PhotoCuller"])
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
        )
    ]
)
