// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Astrolabio",
    defaultLocalization: "es",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Astrolabio", targets: ["Astrolabio"])
    ],
    targets: [
        .executableTarget(
            name: "Astrolabio",
            path: "Sources/Astrolabio"
        ),
        .testTarget(
            name: "AstrolabioTests",
            dependencies: ["Astrolabio"],
            path: "Tests/AstrolabioTests"
        )
    ]
)
