// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GrokBotCore",
    products: [
        .library(name: "GrokBotCore", targets: ["GrokBotCore"])
    ],
    targets: [
        .target(name: "GrokBotCore"),
        .testTarget(name: "GrokBotCoreTests", dependencies: ["GrokBotCore"])
    ]
)
