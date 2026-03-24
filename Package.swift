// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MarkLens",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MarkLens", targets: ["MarkLens"])
    ],
    targets: [
        .executableTarget(
            name: "MarkLens",
            path: "Sources/MarkLens",
            resources: [
                .process("Assets.xcassets"),
                .copy("PrivacyInfo.xcprivacy")
            ],
            swiftSettings: [
                // Swift 6 strict concurrency causes a compiler crash (signal 6) on the
                // macOS 15 SDK used by GitHub Actions runners. Swift 5 mode fixes it.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
