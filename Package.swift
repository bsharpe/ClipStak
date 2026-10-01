// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipStak",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipStak", targets: ["ClipStak"])
    ],
    targets: [
        .target(name: "ClipStakCore"),
        .executableTarget(
            name: "ClipStak",
            dependencies: ["ClipStakCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "ClipStakCoreTests", dependencies: ["ClipStakCore"]),
    ]
)
