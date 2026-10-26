// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DropPrompter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DropPrompter", path: "Sources/DropPrompter")
    ]
)
