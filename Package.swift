// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Islet",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IsletCore"),
        .executableTarget(name: "Islet", dependencies: ["IsletCore"]),
        .testTarget(name: "IsletCoreTests", dependencies: ["IsletCore"]),
    ],
    swiftLanguageModes: [.v5]
)
