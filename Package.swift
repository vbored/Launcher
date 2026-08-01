// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Launcher",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Launcher",
            path: "Sources/LaunchBack",
            linkerSettings: [
                // Carbon.HIToolbox backs the global hotkey (RegisterEventHotKey).
                // It ships on every Mac, Intel and Apple Silicon alike, and needs
                // no Accessibility/Input Monitoring entitlement unlike a CGEventTap.
                .linkedFramework("Carbon")
            ]
        )
    ]
)
