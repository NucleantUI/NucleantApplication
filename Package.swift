// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NucleantApplication",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "NucleantApplication",
            targets: ["NucleantApplication"]
        ),
        .library(name: "NucleantWindow", targets: ["NucleantWindow"])
    ],
    dependencies: [
        .package(path: "../NucleantVulkan")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "NucleantApplication",
            dependencies: [
                "NucleantWindow",
                .byName(name: "Platform_MacOS", condition: .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "Platform_MacOS",
            dependencies: [
                "NucleantWindow"
            ]
        ),
        .target(
            name: "NucleantWindow",
            dependencies: [
                .product(name: "VulkanCore", package: "NucleantVulkan"),
                .product(name: "NucleantVulkan", package: "NucleantVulkan"),
            
            ]
        ),
        .testTarget(
            name: "NucleantApplicationTests",
            dependencies: [
                "NucleantApplication",
            ]
        ),
    ]
)
