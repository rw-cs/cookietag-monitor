// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CookieTagMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CookieTagMonitor",
            path: "Sources/CookieTagMonitor"
        )
    ]
)
