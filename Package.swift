// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageMeter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UsageMeter",
            path: "Sources/UsageMeter",
            // Only what the app loads at runtime (the provider marks). The app
            // icon and marketing logos also live in Resources/ but are consumed
            // by build.sh and the site, not by code — bundling them doubled the
            // shipped app's resource weight for no reader.
            resources: [
                .copy("Resources/claude-logo.png"),
                .copy("Resources/codex-logo.png"),
                .copy("Resources/gemini-logo.png")
            ]
        ),
        .testTarget(
            name: "UsageMeterTests",
            dependencies: ["UsageMeter"],
            path: "Tests/UsageMeterTests"
        )
    ]
)
