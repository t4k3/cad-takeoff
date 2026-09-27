// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElectronicsCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ElectronicsCore", targets: ["ElectronicsCore"]),
        .executable(name: "electronics-check", targets: ["ElectronicsCheck"]),
        .executable(name: "electronics-library", targets: ["ElectronicsLibraryCLI"])
    ],
    targets: [
        .target(name: "ElectronicsCore"),
        .executableTarget(name: "ElectronicsCheck", dependencies: ["ElectronicsCore"]),
        .executableTarget(name: "ElectronicsLibraryCLI", dependencies: ["ElectronicsCore"]),
        .testTarget(name: "ElectronicsCoreTests", dependencies: ["ElectronicsCore"],
                    resources: [.copy("Fixtures")])
    ]
)
