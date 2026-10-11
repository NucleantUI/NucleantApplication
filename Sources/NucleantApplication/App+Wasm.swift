//
//  App+Wasm.swift
//  NucleantApplication
//

#if os(WASI)
import Dispatch
import NucleantWindow
import Platform_Wasm

extension NucleantApplication {
    public func setup() {
        // A page has no application object to hand a delegate to, so — as on
        // Linux and Android — `setup()` only builds the lifecycle object, and
        // starting it is an explicit `run()`.
        appDelegate = AppDelegate(app: self)
    }

    /// Fires `onStart()` and returns.
    ///
    /// Like Android, and unlike the desktop platforms, this does not block:
    /// the browser owns the event loop, and the module only runs when the
    /// page calls into it (a display refresh, an input event). Blocking here
    /// would freeze the page. So `run()` hands the app over to the page —
    /// which keeps it alive from then on, the way `NSApplication` keeps its
    /// delegate — and returns; `main` returning is the normal end of startup.
    public func run() throws {
        guard let appDelegate else { return }
        appDelegate.run()
    }
}

/// Owns the browser app lifecycle. The parallel of the `NSApplicationDelegate`
/// / `UIApplicationDelegate` classes of the same name and of the Linux and
/// Android ones — minus a framework protocol, since there is nothing here to
/// conform to.
@MainActor
public final class AppDelegate<App: NucleantApplication> {

    weak var app: App?

    /// A page has no menu bar to fill.
    public let menuBarHost = NoMenuBar()

    public init(app: App) {
        self.app = app
    }

    /// `onStart()` is where windows get created; each window joins the
    /// page's frame loop as it's made.
    public func run() {
        // Held for the page from here on: once `main` returns nothing on the
        // Swift side references the app any more.
        if BrowserApplication.running == nil, let app {
            BrowserApplication.running = Unmanaged.passRetained(app).toOpaque()
        }
        // `main` is about to return to the page, and with it the runtime's
        // own job drain: from here on tasks run on the page's main queue.
        MainQueueExecutor.install()
        app?.onStart()
    }

    /// Lets the app go: windows it still holds are torn down with it. The
    /// page itself stays — a browser tab isn't the module's to close.
    public func terminate() {
        guard let running = BrowserApplication.running else { return }
        BrowserApplication.running = nil
        Unmanaged<App>.fromOpaque(running).release()
    }
}

/// Where the page keeps the running app: one retained pointer, whatever the
/// `App` type of the `AppDelegate` that set it.
@MainActor
private enum BrowserApplication {
    static var running: UnsafeMutableRawPointer?
}
#endif
