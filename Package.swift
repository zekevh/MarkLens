// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MarkLens",
    platforms: [.macOS(.v26)],
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
