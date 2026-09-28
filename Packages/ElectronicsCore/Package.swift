// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElectronicsCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ElectronicsCore", targets: ["ElectronicsCore"]),
        .executable(name: "electronics-check", targets: ["ElectronicsCheck"]),
        .executable(name: "electronics-library", targets: ["ElectronicsLibraryCLI"]),
        .executable(name: "electronics-pcb", targets: ["ElectronicsPCBCheck"]),
        .executable(name: "electronics-fabrication", targets: ["ElectronicsFabricationCLI"]),
        .executable(name: "electronics-import", targets: ["ElectronicsImportCLI"]),
        .executable(name: "electronics-assembly", targets: ["ElectronicsAssemblyCLI"]),
        .executable(name: "electronics-schematic", targets: ["ElectronicsSchematicCheck"])
    ],
    targets: [
        .target(name: "CElectronicsArchive", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "ElectronicsCore", dependencies: ["CElectronicsArchive"]),
        .executableTarget(name: "ElectronicsCheck", dependencies: ["ElectronicsCore"]),
        .executableTarget(name: "ElectronicsPCBCheck", dependencies: ["ElectronicsCore"]),
        .executableTarget(name: "ElectronicsFabricationCLI", dependencies: ["ElectronicsCore"]),
        .executableTarget(name: "ElectronicsImportCLI", dependencies: ["ElectronicsCore"]),
        .executableTarget(name: "ElectronicsAssemblyCLI", dependencies: ["ElectronicsCore"]),
        .executableTarget(name: "ElectronicsSchematicCheck", dependencies: ["ElectronicsCore"]),
        .executableTarget(name: "ElectronicsLibraryCLI", dependencies: ["ElectronicsCore"]),
        .testTarget(name: "ElectronicsCoreTests", dependencies: ["ElectronicsCore"],
                    resources: [.copy("Fixtures")])
    ]
)
