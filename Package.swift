// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Moonvisor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Moonvisor",
            path: "Sources/Moonvisor",
            linkerSettings: [.linkedFramework("Virtualization")]
        )
    ]
)
