// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkLens",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MarkLens", targets: ["MarkLens"])
    ],
    targets: [
        .executableTarget(
            name: "MarkLens",
            path: "Sources/MarkLens"
        )
    ]
)
