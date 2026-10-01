// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stack",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Stack", targets: ["Stack"])
    ],
    targets: [
        .target(name: "StackCore"),
        .executableTarget(
            name: "Stack",
            dependencies: ["StackCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "StackCoreTests", dependencies: ["StackCore"]),
    ]
)
