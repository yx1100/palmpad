// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTMKit",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "Wire", targets: ["Wire"]),
        .library(name: "Engine", targets: ["Engine"]),
    ],
    targets: [
        .target(name: "Wire"),
        .target(name: "Engine", dependencies: ["Wire"]),
        .testTarget(name: "WireTests", dependencies: ["Wire"]),
        .testTarget(name: "EngineTests", dependencies: ["Engine"]),
    ],
    swiftLanguageModes: [.v5]
)
