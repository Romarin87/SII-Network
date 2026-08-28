// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetWatchSII",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NetWatchSII", targets: ["NetWatchSII"])
    ],
    targets: [
        .executableTarget(
            name: "NetWatchSII",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Charts"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
