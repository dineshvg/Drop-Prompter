// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DropPrompter",
    platforms: [.macOS("15.0")], // Translation framework
    dependencies: [
        // Terminal emulator for the built-in terminal pane (MIT).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "DropPrompter",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/DropPrompter"
        )
    ]
)
