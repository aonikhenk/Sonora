// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sonora",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Sonora", path: "Sources/Sonora")
    ]
)
