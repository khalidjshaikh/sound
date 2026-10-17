// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "sound",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "sound", targets: ["sound"]),
        .library(name: "SoundModem", targets: ["SoundModem"]),
    ],
    targets: [
        .target(name: "SoundModem"),
        .executableTarget(name: "sound", dependencies: ["SoundModem"]),
        .testTarget(name: "SoundModemTests", dependencies: ["SoundModem"]),
    ]
)
