// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentOpsBar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "AgentOpsBar", targets: ["AgentOpsBar"]),
    ],
    targets: [
        .executableTarget(
            name: "AgentOpsBar",
            path: "Sources/AgentOpsBar"
        ),
        .testTarget(
            name: "AgentOpsBarTests",
            dependencies: ["AgentOpsBar"],
            path: "Tests/AgentOpsBarTests"
        ),
    ]
)
