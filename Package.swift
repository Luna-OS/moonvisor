// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Moonvisor",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Moonvisor", targets: ["Moonvisor"]),
        .executable(name: "moonctl", targets: ["moonctl"]),
        .library(name: "MoonvisorCore", targets: ["MoonvisorCore"]),
    ],
    targets: [
        .target(name: "MoonvisorCore"),
        .executableTarget(name: "Moonvisor", dependencies: ["MoonvisorCore"]),
        .executableTarget(name: "moonctl", dependencies: ["MoonvisorCore"]),
        .testTarget(name: "MoonvisorCoreTests", dependencies: ["MoonvisorCore"]),
    ]
)
