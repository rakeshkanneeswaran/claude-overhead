// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Chimlo",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ChimloCore", targets: ["ChimloCore"]),
        .library(name: "ChimloProtocol", targets: ["ChimloProtocol"]),
        .executable(name: "ChimloApp", targets: ["ChimloApp"]),
        .executable(name: "overhead", targets: ["ChimloCLI"]),
        .executable(name: "overhead-check", targets: ["ChimloChecks"]),
        .executable(name: "overhead-release-notes", targets: ["ChimloReleaseNotes"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.2"
        ),
    ],
    targets: [
        .target(name: "ChimloCore"),
        .target(
            name: "ChimloProtocol",
            dependencies: ["ChimloCore"]
        ),
        .executableTarget(
            name: "ChimloApp",
            dependencies: [
                "ChimloCore",
                "ChimloProtocol",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "ChimloCLI",
            dependencies: ["ChimloCore", "ChimloProtocol"]
        ),
        .executableTarget(
            name: "ChimloChecks",
            dependencies: ["ChimloCore", "ChimloProtocol"]
        ),
        // Checks and publishes a release's What's New (see Docs/RELEASING.md).
        .executableTarget(
            name: "ChimloReleaseNotes",
            dependencies: ["ChimloCore"]
        ),
        .testTarget(
            name: "ChimloCoreTests",
            dependencies: ["ChimloCore"]
        ),
        .testTarget(
            name: "ChimloProtocolTests",
            dependencies: ["ChimloCore", "ChimloProtocol"]
        ),
    ]
)
