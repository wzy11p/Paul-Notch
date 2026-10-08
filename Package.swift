// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaulNotch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PaulNotch", targets: ["PaulNotchApp"]),
        .executable(name: "PaulCredentialAgent", targets: ["PaulCredentialAgent"]),
        .executable(name: "PaulCredentialAgentV2", targets: ["PaulCredentialAgentV2"]),
    ],
    dependencies: [
        .package(url: "https://github.com/6tail/lunar-swift.git", exact: "1.1.8"),
    ],
    targets: [
        .executableTarget(name: "PaulCredentialAgent", path: "Sources/PaulCredentialAgent"),
        .executableTarget(name: "PaulCredentialAgentV2", path: "Sources/PaulCredentialAgentV2"),
        .target(
            name: "PaulNotchCore",
            dependencies: [
                .product(name: "LunarSwift", package: "lunar-swift"),
            ],
            path: "Sources/PaulNotchCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "PaulNotchApp",
            dependencies: ["PaulNotchCore"],
            path: "Sources/PaulNotchApp"
        ),
        .testTarget(
            name: "PaulNotchCoreTests",
            dependencies: ["PaulNotchCore"],
            path: "Tests/PaulNotchCoreTests",
            swiftSettings: [.define("SWIFT_PACKAGE_TESTS")]
        ),
    ]
)
