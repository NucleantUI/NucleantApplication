// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let devMode = true

func getDependencies() -> [Package.Dependency] {
    if devMode {
        return [
            .package(path: "../NucleantVulkan")
        ]
    }
    return [
        .package(url: "https://github.com/NucleantUI/NucleantVulkan", branch: "master"),
    ]
}

// The Linux window/app provider (Platform_Linux + its CWayland C module) is
// declared only when the package is being built *on* Linux. A
// `.when(platforms: [.linux])` condition can only gate a dependency edge, not
// whether a target exists — and CWayland can't exist on Apple at all: it
// compiles wayland-scanner output against <wayland-client.h>, which no Apple
// SDK has. Package.swift is compiled by the host toolchain, so `#if os(Linux)`
// here means "host is Linux", which for this package is the same thing as
// "target is Linux": unlike Android there is no cross-compile path into it.
#if os(Linux)
let isLinux = true
#else
let isLinux = false
#endif

func platformProducts() -> [Product] {
    var products: [Product] = [
        .library(name: "Platform_MacOS", targets: ["Platform_MacOS"]),
        .library(name: "Platform_iOS", targets: ["Platform_iOS"])
    ]
    if isLinux {
        products.append(.library(name: "Platform_Linux", targets: ["Platform_Linux"]))
    }
    return products
}

func platformTargets() -> [Target] {
    var targets: [Target] = [
        .target(
            name: "Platform_MacOS",
            dependencies: [
                "NucleantWindow"
            ]
        ),
        .target(
            name: "Platform_iOS",
            dependencies: [
                "NucleantWindow"
            ]
        )
    ]
    if isLinux {
        targets.append(contentsOf: [
            // Wayland: the system libwayland-client, plus the vendored
            // xdg-shell / xdg-decoration code libwayland doesn't ship — see
            // Sources/CWayland/README.md. A `.systemLibrary` target can't be
            // used (there's C to compile, not just headers to point at), so
            // the library is linked by name and the headers come from
            // /usr/include; `libwayland-dev` supplies both.
            .target(
                name: "CWayland",
                path: "Sources/CWayland",
                exclude: ["protocols", "README.md"],
                sources: ["xdg-shell-protocol.c", "xdg-decoration-protocol.c"],
                publicHeadersPath: "include",
                linkerSettings: [
                    .linkedLibrary("wayland-client")
                ]
            ),
            .target(
                name: "Platform_Linux",
                dependencies: [
                    "NucleantWindow",
                    "CWayland"
                ]
            ),
            // `swift run WaylandProbe` — opens a toplevel with no renderer
            // behind it and logs what the compositor sends back. There's no
            // Linux equivalent of just running the app in Xcode yet, and this
            // is the smallest thing that answers "does the window/input layer
            // work on this desktop". Delete it once a real Linux host exists.
            .executableTarget(
                name: "WaylandProbe",
                dependencies: [
                    "Platform_Linux",
                    "NucleantWindow",
                    // Direct, for the shm buffer the probe paints itself —
                    // Platform_Linux has no use for wl_shm.
                    "CWayland",
                    .product(name: "NucleantVulkan", package: "NucleantVulkan")
                ]
            )
        ])
    }
    return targets
}

/// NucleantApplication's per-platform window provider. Only one is ever in
/// scope for a given build, which is what lets `PlatformWindow` /
/// `AppDelegate` be one name across all three.
func platformDependencies() -> [Target.Dependency] {
    var deps: [Target.Dependency] = [
        .byName(name: "Platform_MacOS", condition: .when(platforms: [.macOS])),
        .byName(name: "Platform_iOS", condition: .when(platforms: [.iOS]))
    ]
    if isLinux {
        deps.append(.byName(name: "Platform_Linux", condition: .when(platforms: [.linux])))
    }
    return deps
}

let package = Package(
    name: "NucleantApplication",
    platforms: [
        // iOS 17 to match NucleantVulkan (Observation framework floor); the
        // parallel of the macOS(.v14) minimum.
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "NucleantApplication",
            targets: ["NucleantApplication"]
        ),
        .library(name: "NucleantWindow", targets: ["NucleantWindow"])
    ] + platformProducts(),
    dependencies: getDependencies(),
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "NucleantApplication",
            dependencies: [
                "NucleantWindow"
            ] + platformDependencies()
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
    ] + platformTargets()
)
