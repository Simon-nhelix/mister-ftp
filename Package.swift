// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MiSTerFTP",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MiSTerFTP", targets: ["MiSTerFTP"]),
    ],
    targets: [
        // FTP client, list parsing and LAN discovery. No UI code.
        .target(name: "FTPKit"),
        // Finds, checks and installs new releases from GitHub. No UI code.
        .target(name: "UpdateKit"),
        // The SwiftUI app.
        .executableTarget(name: "MiSTerFTP", dependencies: ["FTPKit", "UpdateKit"]),
        .testTarget(name: "FTPKitTests", dependencies: ["FTPKit"]),
        .testTarget(name: "UpdateKitTests", dependencies: ["UpdateKit"]),
    ],
    swiftLanguageModes: [.v5]
)
