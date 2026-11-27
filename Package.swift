// swift-tools-version: 6.2
// soho-monitor: native macOS system monitor (menu bar + desktop panel), SwiftUI, macOS 26+.
import PackageDescription

let package = Package(
    name: "soho-monitor",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SohoMonitor", targets: ["SohoMonitor"]),
        .library(name: "SohoMonitorCore", targets: ["SohoMonitorCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0")
    ],
    targets: [
        // Platform-independent logic: configuration, sampling, disk scan, models. Unit-tested.
        .target(
            name: "SohoMonitorCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        // SwiftUI app: menu bar extra and desktop panel. Bundled as .app by scripts/bundle-app.sh.
        .executableTarget(
            name: "SohoMonitor",
            dependencies: ["SohoMonitorCore"]
        ),
        .testTarget(
            name: "SohoMonitorCoreTests",
            dependencies: ["SohoMonitorCore"],
            // Anonymised DSM responses (Synology), read byte for byte.
            resources: [.copy("Fixtures")]
        ),
    ]
)
