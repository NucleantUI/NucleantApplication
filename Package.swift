// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// Build against the sibling checkouts (`../NucleantVulkan`) or against GitHub.
///
/// Decided the same way in every Nucleant package, so one setting covers the
/// whole chain: `NUCLEANT_LOCAL_DEV=1|0` in the environment wins; otherwise
/// local when the sibling checkout exists next to this package — true in a
/// development tree, false for a clone SwiftPM made under `.build/checkouts`,
/// which is what lets a git consumer resolve the chain without editing
/// anything. Path dependencies are not allowed in a package fetched by
/// revision, so a hardcoded `true` on master breaks every remote consumer.
let devMode: Bool = {
    if let flag = ProcessInfo.processInfo.environment["NUCLEANT_LOCAL_DEV"] {
        return ["1", "true", "yes"].contains(flag.lowercased())
    }
    let siblings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return FileManager.default.fileExists(atPath: siblings.appendingPathComponent("NucleantVulkan").path)
}()

let env = ProcessInfo.processInfo.environment

let PSK_DEVELOPMENT = env["PSK_DEVELOPMENT"] == "1"
let PIP_MODE = env["PIP_MODE"] == "1"

let env = ProcessInfo.processInfo.environment

let PSK_DEVELOPMENT = env["PSK_DEVELOPMENT"] == "1"
let PIP_MODE = env["PIP_MODE"] == "1"

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
// Android is always a cross-compile — Package.swift is compiled by the *host*
// toolchain, so `#if os(Android)` here would describe the host and never be
// true. It is an explicit env opt-in, the same signal NucleantVulkan, CPython,
// PySwiftKit and PyNucleantUI all use.
let isAndroid = ProcessInfo.processInfo.environment["SWIFT_ANDROID_HOME"] != nil
    || ProcessInfo.processInfo.environment["ANDROID_BUILD"] != nil

#if os(Linux)
// `&& !isAndroid`: the Android host *is* Linux, and a `.when(platforms:)`
// condition only gates linking, not whether a target exists — so without this
// the Linux provider still gets built, and CWayland fails immediately on
// <wayland-util.h>, which no NDK sysroot has.
let isLinux = !isAndroid
#else
let isLinux = false
#endif

/// Every module the package vends, for PIP_MODE's single dynamic library.
/// Platform_Linux and Platform_Android join the list on their own host for the
/// same reason they get their own product elsewhere: only one platform provider
/// exists per build. The Apple two are unconditional because their sources are
/// `#if os(...)`-guarded and so compile to empty modules everywhere else.
func pipProductTargets() -> [String] {
    var targets = ["NucleantApplication", "NucleantWindow", "Platform_MacOS", "Platform_iOS"]
    if isLinux {
        targets.append("Platform_Linux")
    }
    if isAndroid {
        targets.append("Platform_Android")
    }
    return targets
}

func platformProducts() -> [Product] {
    var products: [Product] = [
        .library(name: "Platform_MacOS", type: .static, targets: ["Platform_MacOS"]),
        .library(name: "Platform_iOS", type: .static, targets: ["Platform_iOS"])
    ]
    if isLinux {
        products.append(.library(name: "Platform_Linux", type: .static, targets: ["Platform_Linux"]))
    }
    if isAndroid {
        products.append(.library(name: "Platform_Android", type: .static, targets: ["Platform_Android"]))
    }
    return products
}

func packageProducts() -> [Product] {
    if PIP_MODE {
        // One dynamic library for the whole package. SwiftPM links a
        // same-package target dependency *statically* even when that target is
        // also its own dynamic product, so a product per target would put
        // Platform_MacOS in both libPlatform_MacOS.dylib and
        // libNucleantApplication.dylib (which depends on it), and NucleantWindow
        // in all three. Two copies of a module in one process means two type
        // descriptors: WindowBase's `NucleantWindow` conformance registers
        // against one copy while PlatformWindow<WindowBase> resolves against the
        // other, so instantiating that generic's metadata returns null and the
        // field-offset load segfaults. Shipping every target in a single image
        // keeps exactly one descriptor per module. Consumers import the modules
        // they need — a library product vends all of its targets' modules.
        return [
            .library(
                name: "NucleantApplication",
                type: .static,
                targets: pipProductTargets()
            )
        ]
    }
    // Static/Xcode mode: one product per target, all linked once into the
    // app binary and deduplicated by the static linker — no duplication to
    // avoid, and consumers keep addressing the products individually.
    return [
        .library(
            name: "NucleantApplication",
            type: .static,
            targets: ["NucleantApplication"]
        ),
        .library(name: "NucleantWindow", type: .static, targets: ["NucleantWindow"])
    ] + platformProducts()
}

func platformTargets() -> [Target] {
    var targets: [Target] = [
        .target(
            name: "Platform_MacOS",
            dependencies: [
                "NucleantWindow",
                .product(name: "NucleantVulkan", package: "NucleantVulkan"),
            ]
        ),
        .target(
            name: "Platform_iOS",
            dependencies: [
                "NucleantWindow",
                .product(name: "NucleantVulkan", package: "NucleantVulkan"),
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
            // libxcb core only — no xcb-icccm/xcb-ewmh. WM_PROTOCOLS,
            // WM_DELETE_WINDOW, _NET_WM_NAME etc. are set with plain
            // xcb_change_property calls in X11Display/X11Window rather than
            // pulling in those convenience libraries for a handful of atoms.
            .systemLibrary(
                name: "CXCB",
                path: "Sources/CXCB"
            ),
            .target(
                name: "Platform_Linux",
                dependencies: [
                    "NucleantWindow",
                    "CWayland",
                    "CXCB"
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
    if isAndroid {
        // No C shim of its own: the ANativeWindow handle arrives from the
        // bootstrap through a C ABI, and Vulkan's Android surface extension is
        // reached through NucleantVulkan's CVulkan (the NDK provides both).
        targets.append(.systemLibrary(name: "CAndroidChoreographer"))
        targets.append(
            .target(
                name: "Platform_Android",
                dependencies: [
                    "NucleantWindow",
                    "CAndroidChoreographer",
                    .product(name: "NucleantVulkan", package: "NucleantVulkan"),
                    .product(name: "VulkanCore", package: "NucleantVulkan")
                ]
            )
        )
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
    if isAndroid {
        deps.append(.byName(name: "Platform_Android", condition: .when(platforms: [.android])))
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
    products: packageProducts(),
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
                .product(name: "NucleantShader", package: "NucleantVulkan"),
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
