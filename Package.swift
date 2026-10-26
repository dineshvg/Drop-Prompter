// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DropPrompter",
    platforms: [.macOS("15.0")], // Translation framework
    targets: [
        .executableTarget(name: "DropPrompter", path: "Sources/DropPrompter")
    ]
)
