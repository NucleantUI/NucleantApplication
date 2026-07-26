//
//  App+iOS.swift
//  NucleantApplication
//

#if os(iOS)
import UIKit
import NucleantWindow

/// The `UIWindowScene` the app's window(s) should attach to. Set by the
/// app's scene delegate (`scene(_:willConnectTo:options:)`) before it
/// triggers the Python bootstrap, so that by the time a Python `WindowBase`
/// calls `present()` there's a real scene to build its `UIWindow` from —
/// `UIWindow(windowScene:)` (not a bare frame) is what makes the window
/// track Stage Manager resizing automatically instead of a hardcoded size.
public enum ActiveScene {
    public nonisolated(unsafe) static var current: UIWindowScene?
}

extension NucleantApplication {
    public func setup() {
        // Unlike macOS — where `setup()` creates NSApplication.shared and
        // installs the delegate that drives the whole lifecycle — iOS inverts
        // this: `UIApplicationMain` (started from PyApp.run on iOS) owns the
        // UIApplication and instantiates the delegate. Here we only build and
        // retain the delegate object so it exists and holds a back-reference to
        // the app; PyApp.run performs the UIApplicationMain hand-off that makes
        // `applicationDidFinishLaunching` — and therefore `onStart()` — fire.
        appDelegate = AppDelegate(app: self)
    }
}

public final class AppDelegate<App: NucleantApplication>: UIResponder, UIApplicationDelegate {

    weak var app: App?

    public var window: UIWindow?

    public init(app: App) {
        self.app = app
        super.init()
    }

    public override init() {
        self.app = nil
        super.init()
    }

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        app?.onStart()
        return true
    }
}
#endif
