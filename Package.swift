// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(
            name: "Tether",
            path: "Sources/Tether"
        )
    ],
    swiftLanguageVersions: [.v5]
)
