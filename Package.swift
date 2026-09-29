// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeSessionManager",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClaudeSessionManager", targets: ["ClaudeSessionManager"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudeSessionManager",
            path: "Sources/ClaudeSessionManager"
        )
    ]
)
