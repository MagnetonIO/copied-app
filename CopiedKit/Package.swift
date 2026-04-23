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
        .target(
            name: "CopiedKit",
            swiftSettings: [
                // Ensure DEBUG is defined for Debug builds of the package so
                // the `#if DEBUG` bypass paths in PurchaseManager (and any
                // future package code) evaluate correctly under Xcode's
                // Debug configuration. Without this, Xcode 26's SPM
                // integration can skip propagating the consumer target's
                // DEBUG flag into the package's compile.
                .define("DEBUG", .when(configuration: .debug))
            ]
        )
    ]
)
