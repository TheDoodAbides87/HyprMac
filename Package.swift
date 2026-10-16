// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HyprMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HyprMac",
            path: "Sources/HyprMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
