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

#if os(macOS)
// The SwiftUI app is AppKit/ScreenCaptureKit only, so it is not part of the
// package on other hosts (SwayCore still builds and tests anywhere).
// Scripts/package-app.sh wraps this executable into a clickable Sway.app.
package.products.append(.executable(name: "SwayApp", targets: ["SwayApp"]))
package.targets.append(
    .executableTarget(name: "SwayApp", dependencies: ["SwayCore", "SwayCapture"])
)
#endif
