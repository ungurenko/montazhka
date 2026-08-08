// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Montazhka",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MontazhkaCore",
            path: "Sources/MontazhkaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Montazhka",
            dependencies: ["MontazhkaCore"],
            path: "Sources/Montazhka",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MontazhkaTests",
            dependencies: ["Montazhka", "MontazhkaCore"],
            path: "Tests/MontazhkaTests"
        )
    ]
)
