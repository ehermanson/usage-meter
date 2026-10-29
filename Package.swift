// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageMeter",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CompanionKit", targets: ["CompanionKit"])],
    targets: [
        .target(name: "CompanionKit"),
        .executableTarget(
            name: "UsageMeter",
            dependencies: ["CompanionKit"],
            path: "Sources/UsageMeter",
            exclude: [
                "Resources/UsageMeter.icns", "Resources/usage-meter-app-icon.png",
                "Resources/usage-meter-logo.png", "Resources/usage-meter-logo.svg",
            ],
            // Only what the app loads at runtime (the provider marks). The app
            // icon and marketing logos also live in Resources/ but are consumed
            // by build.sh and the site, not by code — bundling them doubled the
            // shipped app's resource weight for no reader.
            resources: [
                .copy("Resources/claude-logo.png"),
                .copy("Resources/openai-logo.png"),
                .copy("Resources/gemini-logo.png"),
            ]
        ),
        .testTarget(
            name: "CompanionKitTests",
            dependencies: ["CompanionKit"]
        ),
        .testTarget(
            name: "UsageMeterTests",
            dependencies: ["UsageMeter"],
            path: "Tests/UsageMeterTests"
        ),
    ]
)
