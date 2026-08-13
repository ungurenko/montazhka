// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Montazhka",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        )
    ],
    targets: [
        .target(
            name: "MontazhkaCore",
            path: "Sources/MontazhkaCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Montazhka",
            dependencies: [
                "MontazhkaCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Montazhka",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MontazhkaTests",
            dependencies: ["Montazhka", "MontazhkaCore"],
            path: "Tests/MontazhkaTests"
        )
    ]
)
