// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NekozeFix",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "NekozeFix",
            targets: ["NekozeFix"]),
    ],
    targets: [
        .target(
            name: "NekozeFix",
            dependencies: []),
        .testTarget(
            name: "NekozeFixTests",
            dependencies: ["NekozeFix"]),
    ]
)