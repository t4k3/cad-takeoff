// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CADCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CADCore", targets: ["CADCore"])],
    targets: [
        .target(name: "CADCore"),
        .testTarget(name: "CADCoreTests", dependencies: ["CADCore"])
    ]
)

