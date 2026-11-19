// The Swift Programming Language
// https://docs.swift.org/swift-book
import NucleantWindow

@MainActor
public protocol NucleantApplication: AnyObject {
    
    func onStart()
    
    func setup()

    /// Whether the app quits once its last window closes. `true` unless the
    /// app says otherwise — one with an item in the system tray goes on
    /// without windows. Asked on macOS.
    var terminatesAfterLastWindowClosed: Bool { get }

    /// Whether the app starts with its icon in the Dock and its menus in the
    /// menu bar. `true` unless the app says otherwise — one that starts in
    /// the system tray, with no window, starts without. Asked on macOS, in
    /// `setup()`.
    var showsDockIconAtLaunch: Bool { get }
    
    
    
    
    
    #if os(macOS) || os(iOS) || os(Linux) || os(Android) || os(WASI) || os(Windows)
    // Each platform compiles its own `AppDelegate` type (NSApplicationDelegate
    // on macOS, UIApplicationDelegate on iOS, a plain lifecycle object owning
    // the Wayland event loop on Linux, the Win32 message loop on Windows) —
    // only one is in scope per build, so `AppDelegate<Self>` resolves
    // unambiguously.
    var appDelegate: AppDelegate<Self>? { get set }
    #endif
}

extension NucleantApplication {
    public var terminatesAfterLastWindowClosed: Bool { true }

    public var showsDockIconAtLaunch: Bool { true }
}

#if os(macOS) || os(iOS) || os(Linux) || os(Android) || os(WASI) || os(Windows)
extension NucleantApplication {
    /// Put `commands` up as the app's menu bar, replacing what was there.
    /// Call from `onStart()` or later — the delegate exists from `setup()`,
    /// but a menu bar wants an application to hang off. On a platform with
    /// no menu bar this accepts the commands and shows nothing.
    public func installCommands(_ commands: some WindowCommands) {
        appDelegate?.menuBarHost.install(commands.menuBar)
    }

    /// Rebuild the menu bar from the installed `MenuBar` after editing its
    /// menus or commands in place.
    public func refreshCommands() {
        appDelegate?.menuBarHost.refresh()
    }
}
#endif
