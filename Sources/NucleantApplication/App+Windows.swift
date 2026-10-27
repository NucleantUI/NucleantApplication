//
//  App+Windows.swift
//  NucleantApplication
//

#if os(Windows)
import NucleantWindow
import Platform_Windows

extension NucleantApplication {
    public func setup() {
        // Linux's shape: Windows has no application object to hand a delegate
        // to, so `setup()` builds the object that owns the lifecycle and holds
        // it, and starting it is an explicit `run()`.
        appDelegate = AppDelegate(app: self)
    }

    /// Prepares the process for windows, fires `onStart()`, and hands the
    /// calling thread to the Win32 message loop — the union of what
    /// `NSApplication.run()` and `applicationDidFinishLaunching` do on macOS.
    /// Returns when the last window closes or `terminate()` is called.
    public func run() throws {
        guard let appDelegate else {
            throw Win32Error.notSetUp
        }
        try appDelegate.run()
    }
}

/// Owns the Windows app lifecycle. The parallel of the `AppDelegate` classes
/// of the other platforms: a back-reference to the app and the point where
/// `onStart()` fires.
@MainActor
public final class AppDelegate<App: NucleantApplication> {

    weak var app: App?

    /// Win32 menus hang off each window; this puts the app's commands on all
    /// of them.
    public let menuBarHost = Win32MenuBar()

    public init(app: App) {
        self.app = app
    }

    /// Blocks until the event loop stops. `onStart()` runs first — that's
    /// where windows get created — after the process is DPI-aware and the
    /// window class exists.
    public func run() throws {
        try Win32EventLoop.shared.prepare()
        app?.onStart()
        Win32EventLoop.shared.run()
    }

    /// Ends the event loop, so a blocked `run()` returns. Windows are left
    /// intact; the counterpart of `NSApplication.stop(_:)` rather than of
    /// `exit()`.
    public func terminate() {
        Win32EventLoop.shared.stop()
    }
}
#endif
