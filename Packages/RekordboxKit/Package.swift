// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RekordboxKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RekordboxKit", targets: ["RekordboxKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift", from: "4.19.0"),
    ],
    targets: [
        .target(
            name: "RekordboxKit",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")]
        ),
        .testTarget(
            name: "RekordboxKitTests",
            dependencies: ["RekordboxKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    // Matches the app target, which also builds in Swift 5 mode.
    swiftLanguageModes: [.v5]
)
