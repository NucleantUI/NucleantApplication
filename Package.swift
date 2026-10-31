// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// Build against the sibling checkouts (`../NucleantVulkan`) or GitHub.
///
/// GitHub unless `NUCLEANT_LOCAL_DEV=1` is in the environment: the sibling
/// checkouts are used only when that turns them on, never just because they
/// are there. Every Nucleant package reads the same variable, so one setting
/// covers the whole chain.
let devMode: Bool = ["1", "true", "yes"].contains(
    (ProcessInfo.processInfo.environment["NUCLEANT_LOCAL_DEV"] ?? "").lowercased()
)

let env = ProcessInfo.processInfo.environment

let PSK_DEVELOPMENT = env["PSK_DEVELOPMENT"] == "1"
let PIP_MODE = env["PIP_MODE"] == "1"

// swift-java, for the Android surface handoff only — `Platform_Android` takes the
// Activity's `android.view.Surface` as a `JavaObject`, which is what carries the
// JNIEnv/jobject pair `ANativeWindow_fromSurface` needs.
//
// Pinned rather than floored: 0.1.2 introduced the `SwiftJava` product name but
// does not compile on Swift 6.3.3, and it needs swift-syntax 603 — so a package
// in the graph pinning swift-syntax `exact:` to 602 resolves swift-java back down
// to 0.1.2 and reintroduces that failure. ksproject asks for the same version in
// the app's generated manifest; the two have to agree.
//
// Only the runtime product is used here. jextract — the part that wants a JDK —
// stays in the app's package, because it reads syntax and so only sees the
// `public func`s in the target its plugin is attached to.
let SWIFT_JAVA_VERSION: Version = "0.4.2"

func getDependencies() -> [Package.Dependency] {
    var deps: [Package.Dependency] = devMode
        ? [.package(path: "../NucleantVulkan")]
        // By release, up to the next major: a branch requirement here would
        // override the version every package above asks for. 0.1.0: the
        // shared VulkanRenderDevice.
        : [.package(url: "https://github.com/NucleantUI/NucleantVulkan", .upToNextMajor(from: "0.1.0"))]
    if isAndroid {
        deps.append(
            .package(url: "https://github.com/swiftlang/swift-java", from: SWIFT_JAVA_VERSION)
        )
    }
    return deps
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
// true. It is an explicit env opt-in, the same signal NucleantVulkan, CPython
// and PySwiftKit use.
let isAndroid = ProcessInfo.processInfo.environment["SWIFT_ANDROID_HOME"] != nil
    || ProcessInfo.processInfo.environment["ANDROID_BUILD"] != nil

// WebAssembly (`swift build --swift-sdk <version>_wasm`) is a cross-compile
// from any host, so — like Android — an explicit opt-in, the same one
// NucleantVulkan reads.
let isWasm = ProcessInfo.processInfo.environment["WASM_BUILD"] == "1"

#if os(Linux)
// `&& !isAndroid`: the Android host *is* Linux, and a `.when(platforms:)`
// condition only gates linking, not whether a target exists — so without this
// the Linux provider still gets built, and CWayland fails immediately on
// <wayland-util.h>, which no NDK sysroot has. `!isWasm` for the same reason
// when a Linux host builds for wasm.
let isLinux = !isAndroid && !isWasm
#else
let isLinux = false
#endif

// Windows is native too, like Linux: the Windows toolchain builds for the
// machine it runs on and nothing cross-compiles into it, so the host is the
// target. (NucleantVulkan has a Windows build from 0.0.2, hence the floor
// above.)
#if os(Windows)
let isWindows = true
#else
let isWindows = false
#endif

/// Every module the package vends, for PIP_MODE's single dynamic library.
/// Platform_Linux and Platform_Android join the list on their own host for the
/// same reason they get their own product elsewhere: only one platform provider
/// exists per build. The Apple two are unconditional because their sources are
/// `#if os(...)`-guarded and so compile to empty modules everywhere else.
func pipProductTargets() -> [String] {
    var targets = ["NucleantApplication", "NucleantWindow", "NucleantSync", "Platform_MacOS", "Platform_iOS"]
    if isLinux {
        targets.append("Platform_Linux")
    }
    if isWindows {
        targets.append("Platform_Windows")
    }
    if isAndroid {
        targets.append("Platform_Android")
        targets.append("NucleantBridge")
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
    if isWindows {
        products.append(.library(name: "Platform_Windows", type: .static, targets: ["Platform_Windows"]))
    }
    if isAndroid {
        products.append(.library(name: "Platform_Android", type: .static, targets: ["Platform_Android"]))
        products.append(.library(name: "NucleantBridge", type: .static, targets: ["NucleantBridge"]))
    }
    if isWasm {
        products.append(.library(name: "Platform_Wasm", type: .static, targets: ["Platform_Wasm"]))
        // libdispatch's API for the browser (Sources/DispatchWasm), which the
        // wasm Swift SDK does not ship: `import Dispatch` in code shared with
        // the other platforms resolves to it.
        products.append(.library(name: "Dispatch", type: .static, targets: ["Dispatch"]))
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
        .library(name: "NucleantWindow", type: .static, targets: ["NucleantWindow"]),
        .library(name: "NucleantSync", type: .static, targets: ["NucleantSync"])
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
    if isWindows {
        targets.append(contentsOf: [
            // Win32 through the toolchain's WinSDK module, which links
            // user32, gdi32, dwmapi and advapi32 itself: nothing to declare.
            .target(
                name: "Platform_Windows",
                dependencies: ["NucleantWindow"]
            ),
            // `swift run Win32Probe` — one window with a render engine behind
            // it, logging the input it receives. Windows' counterpart of
            // WaylandProbe and WasmProbe: the smallest thing that answers
            // "does the window, input and render layer work on this machine".
            .executableTarget(
                name: "Win32Probe",
                dependencies: [
                    "NucleantApplication",
                    "NucleantWindow",
                    "Platform_Windows",
                    .product(name: "NucleantVulkan", package: "NucleantVulkan"),
                ]
            ),
        ])
    }
    if isAndroid {
        targets.append(.systemLibrary(name: "CAndroidChoreographer"))
        // android/native_window_jni.h. `ANativeWindow_fromSurface` is the only
        // way from an `android.view.Surface` to the handle
        // VK_KHR_android_surface needs, and it has no Java-side equivalent — so
        // the surface handoff cannot go through swift-java the way the rest of
        // the Java edge does. Headers only, from the Swift Android SDK's
        // sysroot, with libandroid linked by the module map.
        //
        // It lives here rather than in the app's generated package because the
        // code that uses it does: AndroidSurfaceBridge is the other half of
        // AndroidSurfaceHost, and splitting the two across modules is what
        // forced them to meet over a dlsym'd C ABI.
        targets.append(.systemLibrary(name: "CAndroidNativeWindow"))
        // The Java edge: surface, input and lifecycle, as `public func`s that
        // jextract turns into `org.nucleantui.NucleantBridge`.
        //
        // A module of its own rather than more functions in Platform_Android,
        // because the plugin generates Java for *everything* public in the
        // target it is attached to — this way exactly the intended surface
        // crosses, and Platform_Android stays a plain Swift module.
        targets.append(
            .target(
                name: "NucleantBridge",
                dependencies: [
                    "Platform_Android",
                    .product(name: "SwiftJava", package: "swift-java")
                ],
                plugins: [
                    .plugin(name: "JExtractSwiftPlugin", package: "swift-java")
                ]
            )
        )
        targets.append(
            .target(
                name: "Platform_Android",
                dependencies: [
                    "NucleantWindow",
                    "CAndroidChoreographer",
                    "CAndroidNativeWindow",
                    .product(name: "SwiftJava", package: "swift-java"),
                    .product(name: "NucleantVulkan", package: "NucleantVulkan"),
                    .product(name: "VulkanCore", package: "NucleantVulkan")
                ]
            )
        )
    }
    if isWasm {
        targets.append(contentsOf: [
            // The page's side of the window system: imports of the
            // "nucleant_dom" module, which Web/nucleant-app.js implements.
            // Declarations only — the stub is there because SwiftPM wants a
            // source file in a C target.
            .target(
                name: "CWasmDOM",
                path: "Sources/CWasmDOM",
                sources: ["stub.c"],
                publicHeadersPath: "include"
            ),
            .target(
                name: "Platform_Wasm",
                dependencies: [
                    "NucleantWindow",
                    "CWasmDOM",
                    .product(name: "NucleantVulkan", package: "NucleantVulkan"),
                ]
            ),
            // The page's timer and the monotonic clock, for Dispatch below.
            // Declarations only, like CWasmDOM.
            .target(
                name: "CDispatchWasm",
                path: "Sources/CDispatchWasm",
                sources: ["stub.c"],
                publicHeadersPath: "include"
            ),
            // libdispatch's queues and times on the page's one thread, under
            // the name `import Dispatch` looks for — the wasm Swift SDK has
            // no Dispatch, and Foundation there has no Thread or RunLoop. Its
            // main queue is serviced by the page (`mainQueueWake`), and
            // `MainQueueExecutor` makes it Swift concurrency's executor too.
            .target(
                name: "Dispatch",
                dependencies: ["CDispatchWasm"],
                path: "Sources/DispatchWasm"
            ),
            // `scripts/build_wasm_app.py WasmProbe` — one window on the page
            // with a render engine behind it, logging the input it receives.
            // The browser's counterpart of WaylandProbe: the smallest thing
            // that answers "does the window, input and render layer work in
            // this browser".
            .executableTarget(
                name: "WasmProbe",
                dependencies: [
                    "NucleantApplication",
                    "NucleantWindow",
                    "Platform_Wasm",
                    .product(name: "NucleantVulkan", package: "NucleantVulkan"),
                ]
            ),
        ])
    }
    return targets
}

/// NucleantApplication's per-platform window provider. Only one is ever in
/// scope for a given build, which is what lets `PlatformWindow` /
/// `AppDelegate` be one name across all of them.
func platformDependencies() -> [Target.Dependency] {
    var deps: [Target.Dependency] = [
        .byName(name: "Platform_MacOS", condition: .when(platforms: [.macOS])),
        .byName(name: "Platform_iOS", condition: .when(platforms: [.iOS]))
    ]
    if isLinux {
        deps.append(.byName(name: "Platform_Linux", condition: .when(platforms: [.linux])))
    }
    if isWindows {
        deps.append(.byName(name: "Platform_Windows", condition: .when(platforms: [.windows])))
    }
    if isAndroid {
        deps.append(.byName(name: "Platform_Android", condition: .when(platforms: [.android])))
    }
    if isWasm {
        deps.append(.byName(name: "Platform_Wasm", condition: .when(platforms: [.wasi])))
        // The app lifecycle installs the main queue as Swift concurrency's
        // executor (App+Wasm.swift).
        deps.append(.byName(name: "Dispatch", condition: .when(platforms: [.wasi])))
    }
    return deps
}

/// NucleantSync's per-platform sync sources. Linux and Windows have no
/// display-wide vsync callback, so their handlers ride `Platform_Linux`'s and
/// `Platform_Windows`'s event loops; Android's is the Choreographer shim;
/// Apple platforms need nothing from the package.
func syncDependencies() -> [Target.Dependency] {
    var deps: [Target.Dependency] = []
    if isLinux {
        deps.append(.byName(name: "Platform_Linux", condition: .when(platforms: [.linux])))
    }
    if isWindows {
        deps.append(.byName(name: "Platform_Windows", condition: .when(platforms: [.windows])))
    }
    if isAndroid {
        deps.append(.byName(name: "CAndroidChoreographer", condition: .when(platforms: [.android])))
    }
    if isWasm {
        deps.append(.byName(name: "Platform_Wasm", condition: .when(platforms: [.wasi])))
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
        // Display-synced callbacks (DisplaySync). Platform-free dependencies:
        // each platform's sync source lives in a `SyncCallbackHandler+<OS>.swift`.
        .target(name: "NucleantSync", dependencies: syncDependencies()),
        .testTarget(
            name: "NucleantSyncTests",
            dependencies: ["NucleantSync"]
        ),
        .testTarget(
            name: "NucleantApplicationTests",
            dependencies: [
                "NucleantApplication",
            ]
        ),
    ] + platformTargets()
)
