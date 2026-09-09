// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Mechanician",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Mechanician",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Mechanician"
        ),
        .executableTarget(
            name: "MechanicianKeychainHelper",
            path: "Sources/MechanicianKeychainHelper",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication")
            ]
        ),
        .testTarget(
            name: "MechanicianTests",
            dependencies: ["Mechanician"],
            path: "Tests/MechanicianTests",
            // SwiftPM places binary-target frameworks beside the test bundle, while a macOS
            // XCTest executable lives three levels below that directory.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
            ]
        )
    ],
    // Bumped tools-version (needed for .macOS(.v26)) defaults to the Swift 6 language mode; pin v5 so
    // the floor raise doesn't turn on strict-concurrency errors across the whole app at once.
    swiftLanguageModes: [.v5]
)
