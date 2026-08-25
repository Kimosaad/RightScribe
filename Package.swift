// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RightScribe",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "RightScribe", targets: ["RightScribe"])
    ],
    targets: [
        .executableTarget(
            name: "RightScribe",
            path: "Sources/RightScribe",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("Speech")
            ]
        ),
        .testTarget(
            name: "RightScribeTests",
            dependencies: ["RightScribe"],
            path: "Tests/RightScribeTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
