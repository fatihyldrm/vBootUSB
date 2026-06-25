// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "vBootUSB",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "VBootCore", targets: ["VBootCore"]),
        .executable(name: "vbootusb-cli", targets: ["VBootCLI"]),
        .executable(name: "vBootUSB", targets: ["VBootApp"]),
    ],
    targets: [
        .target(
            name: "VBootCore",
            path: "Sources/VBootCore",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "VBootCLI",
            dependencies: ["VBootCore"],
            path: "Sources/VBootCLI"
        ),
        .executableTarget(
            name: "VBootApp",
            dependencies: ["VBootCore"],
            path: "Sources/VBootApp"
        ),
        .testTarget(
            name: "VBootCoreTests",
            dependencies: ["VBootCore"],
            path: "Tests/VBootCoreTests"
        ),
    ]
)
