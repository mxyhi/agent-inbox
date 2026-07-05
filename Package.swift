// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "m-todo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "m-todo", targets: ["MTodoApp"]),
        .library(name: "MTodoCore", targets: ["MTodoCore"])
    ],
    targets: [
        .target(
            name: "MTodoCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "MTodoApp",
            dependencies: ["MTodoCore"]
        ),
        .testTarget(
            name: "MTodoCoreTests",
            dependencies: ["MTodoCore"]
        )
    ]
)
