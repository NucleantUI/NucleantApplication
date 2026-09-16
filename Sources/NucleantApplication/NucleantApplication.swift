// The Swift Programming Language
// https://docs.swift.org/swift-book
import NucleantWindow

@MainActor
public protocol NucleantApplication: AnyObject {
    
    func onStart()
    
    func setup()
    
    
    
    
    
    #if os(macOS) || os(iOS) || os(Linux) || os(Android)
    // Each platform compiles its own `AppDelegate` type (NSApplicationDelegate
    // on macOS, UIApplicationDelegate on iOS, a plain lifecycle object owning
    // the Wayland event loop on Linux) — only one is in scope per build, so
    // `AppDelegate<Self>` resolves unambiguously.
    var appDelegate: AppDelegate<Self>? { get set }
    #endif
}

#if os(macOS) || os(iOS) || os(Linux) || os(Android)
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
