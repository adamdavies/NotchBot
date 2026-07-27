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
    ],
    targets: [
        .target(name: "NotchBotCore"),
        .executableTarget(
            name: "NotchBot",
            dependencies: ["NotchBotCore"],
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "NotchBotHook",
            dependencies: ["NotchBotCore"]
        ),
        .testTarget(
            name: "NotchBotCoreTests",
            dependencies: ["NotchBotCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
