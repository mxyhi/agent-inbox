// swift-tools-version: 6.0

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
    targets: [
        .target(
            name: "AgentInboxCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AgentInboxApp",
            dependencies: ["AgentInboxCore"]
        ),
        .testTarget(
            name: "AgentInboxCoreTests",
            dependencies: ["AgentInboxCore"]
        )
    ]
)
