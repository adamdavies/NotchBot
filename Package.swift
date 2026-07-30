// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchBot",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "NotchBot", targets: ["NotchBot"]),
        .executable(name: "notchbot-hook", targets: ["NotchBotHook"]),
        .library(name: "NotchBotCore", targets: ["NotchBotCore"]),
        .library(name: "NotchBotIntegrationCore", targets: ["NotchBotIntegrationCore"]),
    ],
    targets: [
        .target(name: "NotchBotCore"),
        .target(name: "NotchBotIntegrationCore"),
        .executableTarget(
            name: "NotchBot",
            dependencies: ["NotchBotCore", "NotchBotIntegrationCore"],
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "NotchBotHook",
            dependencies: ["NotchBotCore", "NotchBotIntegrationCore"]
        ),
        .testTarget(
            name: "NotchBotCoreTests",
            dependencies: ["NotchBotCore"]
        ),
        .testTarget(
            name: "NotchBotIntegrationCoreTests",
            dependencies: ["NotchBotIntegrationCore"]
        ),
        .testTarget(
            name: "NotchBotTests",
            dependencies: ["NotchBot"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
