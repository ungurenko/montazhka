// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Montazhka",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Montazhka",
            path: "Sources/Montazhka",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
