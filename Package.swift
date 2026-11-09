// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Snapframe",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Snapframe", targets: ["Snapframe"])],
    targets: [
        .target(name: "SnapframeCore", swiftSettings: swift5),
        .executableTarget(name: "Snapframe", dependencies: ["SnapframeCore"], swiftSettings: swift5),
        .testTarget(name: "SnapframeCoreTests", dependencies: ["SnapframeCore"], swiftSettings: swift5),
    ]
)
