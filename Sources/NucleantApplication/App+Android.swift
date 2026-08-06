//
//  App+Android.swift
//  NucleantApplication
//

#if os(Android)
import NucleantWindow
import Platform_Android

extension NucleantApplication {
    public func setup() {
        // Android has no application singleton for us to own: the Activity is
        // created by the system long before Python starts, and the process is
        // already running by the time this is called. So `setup()` only builds
        // the lifecycle object, the same as Linux — and unlike both Apple
        // platforms, starting it is then an explicit `run()`.
        appDelegate = AppDelegate(app: self)
    }

    /// Fires `onStart()` and returns.
    ///
    /// Unlike every other platform this does *not* block. The Activity owns
    /// the UI thread and the main looper, and the render loop belongs to
    /// `PlatformWindow` (started when a surface appears, stopped when it goes
    /// away) — so there is no event loop here to hand the calling thread to,
    /// and this being a plain `@PyMethod` call means the interpreter's GIL is
    /// held for as long as it runs, which a render thread on its own OS
    /// thread needs periodically to call back into Python. Blocking here
    /// would starve it. Keeping the app alive past this point — until the
    /// Activity's real `onDestroy()` — is therefore the bootstrap's job
    /// (`NucleantLauncher.run`, which is not a Python call and can release
    /// the GIL around a wait the way an embedder normally would), not
    /// `run()`'s.
    public func run() throws {
        guard let appDelegate else { return }
        appDelegate.run()
    }
}

/// Owns the Android app lifecycle. The parallel of the `NSApplicationDelegate`
/// / `UIApplicationDelegate` classes of the same name, and of the Linux one —
/// minus any framework protocol, since there is nothing here to conform to.
@MainActor
public final class AppDelegate<App: NucleantApplication> {

    weak var app: App?

    public init(app: App) {
        self.app = app
    }

    /// `onStart()` is where windows get created, and on Android a window binds
    /// to the Activity's existing surface rather than creating one — so unlike
    /// Linux there is nothing to connect to first.
    public func run() {
        app?.onStart()
    }

    /// No-op counterpart of `NSApplication.stop(_:)`. An Android app does not
    /// terminate itself; the Activity's lifecycle decides that, and the
    /// process goes away when the system reclaims it.
    public func terminate() {}
}
#endif
