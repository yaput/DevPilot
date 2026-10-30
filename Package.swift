// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevPilot",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DevPilot", targets: ["DevPilot"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Domain, integrations and services. No UI imports, fully unit-testable.
        .target(
            name: "DevPilotCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // SwiftUI app: dashboard window, menu-bar extra, settings.
        .executableTarget(
            name: "DevPilot",
            dependencies: ["DevPilotCore"]
        ),
        .testTarget(
            name: "DevPilotCoreTests",
            dependencies: ["DevPilotCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
