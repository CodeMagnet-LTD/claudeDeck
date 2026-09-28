// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeDeck",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ClaudeDeck", targets: ["ClaudeDeck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
    ],
    targets: [
        .target(name: "ClaudeDeckCore"),
        .executableTarget(
            name: "ClaudeDeck",
            dependencies: [
                "ClaudeDeckCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "ClaudeDeckCoreTests",
            dependencies: ["ClaudeDeckCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
