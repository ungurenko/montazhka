// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Montazhka",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MontazhkaKit", targets: ["MontazhkaKit"]),
        .executable(name: "Montazhka", targets: ["MontazhkaExecutable"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        ),
    ],
    targets: [
        .target(
            name: "MontazhkaCore",
            path: "Sources/MontazhkaCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MontazhkaKit",
            dependencies: [
                "MontazhkaCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/Montazhka",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "MontazhkaExecutable",
            dependencies: ["MontazhkaKit"],
            path: "Sources/MontazhkaExecutable",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MontazhkaTests",
            dependencies: ["MontazhkaKit", "MontazhkaCore"],
            path: "Tests/MontazhkaTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
