// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CADCore",
    platforms: [.macOS("27.0")],
    products: [.library(name: "CADCore", targets: ["CADCore"])],
    targets: [
        // Geometry is heavy numeric code: optimised even in Debug builds (10× faster booleans
        // while running the app from Xcode). Local package, so the unsafe flag is allowed.
        .target(name: "CADCore", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "CADCoreTests", dependencies: ["CADCore"])
    ]
)

