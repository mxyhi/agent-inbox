// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "agent-inbox",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "agent-inbox", targets: ["AgentInboxApp"]),
        .library(name: "AgentInboxCore", targets: ["AgentInboxCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .target(
            name: "AgentInboxCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AgentInboxApp",
            dependencies: [
                "AgentInboxCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "AgentInboxCoreTests",
            dependencies: ["AgentInboxCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
