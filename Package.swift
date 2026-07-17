// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Aster", targets: ["Aster"]),
        .library(name: "AsterScreenSaver", type: .dynamic, targets: ["AsterScreenSaver"])
    ],
    targets: [
        .executableTarget(
            name: "Aster",
            path: "Sources/LumaWall",
            resources: [.process("Resources")]
        ),
        .target(
            name: "AsterScreenSaver",
            path: "Sources/AsterScreenSaver",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("ScreenSaver")
            ]
        ),
        .testTarget(
            name: "AsterTests",
            dependencies: ["Aster", "AsterScreenSaver"],
            path: "Tests/AsterTests"
        )
    ]
)
