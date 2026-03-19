// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopiedKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "CopiedKit", targets: ["CopiedKit"])
    ],
    targets: [
        .target(name: "CopiedKit")
    ]
)
