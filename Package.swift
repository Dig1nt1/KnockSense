// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KnockSense",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure-Swift signal processing + data model (no Apple UI frameworks, unit-testable anywhere).
        .target(name: "KnockCore"),
        // The macOS menu-bar app.
        .executableTarget(name: "KnockSense", dependencies: ["KnockCore"]),
        .testTarget(name: "KnockCoreTests", dependencies: ["KnockCore"]),
    ]
)
