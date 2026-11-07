// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cores",
    platforms: [.macOS(.v14)],
    targets: [
        // Small C layer for the SMC and HID temperature sensors (no public Swift API exists).
        .target(
            name: "CSensors",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "Cores",
            dependencies: ["CSensors"]
        ),
    ]
)
