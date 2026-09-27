// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PortCat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PortCat",
            path: "Sources/PortCat"
        )
    ]
)
