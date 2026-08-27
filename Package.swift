// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Headroom",
            path: "Sources/Headroom",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
