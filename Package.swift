// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GalaxySim",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "GalaxySim",
            path: "Sources/GalaxySim",
            resources: [.copy("Shaders"), .copy("Resources/Cabin"), .copy("Resources/Ship")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
