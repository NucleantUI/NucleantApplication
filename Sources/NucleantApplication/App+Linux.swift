//
//  App+Linux.swift
//  NucleantApplication
//

#if os(Linux)
import NucleantWindow
import Platform_Linux

extension NucleantApplication {
    public func setup() {
        // Linux has no OS-owned application singleton to hand a delegate to —
        // there's no NSApplication to become `.shared`, and nothing like
        // UIApplicationMain to instantiate a delegate for us. So `setup()`
        // does the one thing that's left: build the object that owns the
        // lifecycle, and hold it. Unlike both Apple platforms, *starting* it
        // is then an explicit call — see `run()`.
        appDelegate = AppDelegate(app: self)
    }

    /// Connects to the compositor, fires `onStart()`, and hands the calling
    /// thread to the Wayland event loop — the union of what
    /// `NSApplication.run()` and `applicationDidFinishLaunching` do on macOS.
    /// Returns when the last window closes or `terminate()` is called.
    ///
    /// Throws before `onStart()` if there's no compositor to talk to, so a
    /// missing `WAYLAND_DISPLAY` (an X11 session, a bare TTY, a container
    /// without the socket bind-mounted) fails with that as the reason rather
    /// than as a window that won't open.
    public func run() throws {
        guard let appDelegate else {
            // setup() builds it; running without it means the app was never
            // set up, and silently doing nothing would be worse than saying so.
            throw WaylandError.noCompositor
        }
        try appDelegate.run()
    }
}

/// Owns the Linux app lifecycle. The parallel of the `NSApplicationDelegate`
/// / `UIApplicationDelegate` classes of the same name, minus the framework
/// protocol — there is no framework here to conform to, so this is only what
/// the other two add on top: a back-reference to the app and the point where
/// `onStart()` fires.
@MainActor
public final class AppDelegate<App: NucleantApplication> {

    weak var app: App?

    public init(app: App) {
        self.app = app
    }

    /// Blocks until the event loop stops. `onStart()` runs first — that's
    /// where windows get created, and a window has to exist before the loop
    /// has anything to pump.
    public func run() throws {
        try WaylandDisplay.shared.connect()
        app?.onStart()
        WaylandDisplay.shared.run()
    }

    /// Ends the event loop, so a blocked `run()` returns. Windows are left
    /// intact; the counterpart of `NSApplication.stop(_:)` rather than of
    /// `exit()`.
    public func terminate() {
        WaylandDisplay.shared.stop()
    }
}
#endif
