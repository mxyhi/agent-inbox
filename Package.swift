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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        // 便签窗口层（源自 tic，MIT，见 ThirdParty/tic/LICENSE）的存储与 MCP 服务。
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1"))
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
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "AgentInboxCoreTests",
            dependencies: ["AgentInboxCore"]
        ),
        .testTarget(
            name: "AgentInboxAppTests",
            dependencies: [
                "AgentInboxApp",
                "AgentInboxCore",
                .product(name: "MCP", package: "swift-sdk")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
