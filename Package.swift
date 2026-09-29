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
        // The SwiftUI app.
        .executableTarget(name: "MiSTerFTP", dependencies: ["FTPKit"]),
        .testTarget(name: "FTPKitTests", dependencies: ["FTPKit"]),
    ],
    swiftLanguageModes: [.v5]
)
