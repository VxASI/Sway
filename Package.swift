// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sway",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwayCore", targets: ["SwayCore"]),
        .library(name: "SwayCapture", targets: ["SwayCapture"]),
        .executable(name: "sway", targets: ["sway"])
    ],
    targets: [
        .target(name: "SwayCore"),
        .target(name: "SwayCapture", dependencies: ["SwayCore"]),
        .executableTarget(name: "sway", dependencies: ["SwayCore", "SwayCapture"]),
        .testTarget(name: "SwayCoreTests", dependencies: ["SwayCore"])
    ]
)
