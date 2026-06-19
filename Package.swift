// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageMeter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UsageMeter",
            path: "Sources/UsageMeter",
            resources: [
                .copy("Resources/claude-logo.png"),
                .copy("Resources/codex-logo.png")
            ]
        ),
        .testTarget(
            name: "UsageMeterTests",
            dependencies: ["UsageMeter"],
            path: "Tests/UsageMeterTests"
        )
    ]
)
