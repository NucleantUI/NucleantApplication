//
//  App+MacOS.swift
//  NucleantApplication
//

#if os(macOS)
import AppKit
import NucleantWindow
import Platform_MacOS

extension NucleantApplication {
    public func setup() {
        // NSApplication is a singleton: a plain NSApplication() here makes any
        // later sharedApplication call throw "Creating more than one Application".
        let app = NSApplication.shared
        // A process with no app bundle (running the interpreter directly, e.g.
        // `uv run <app>`) starts background-only: AppKit builds windows and the
        // display link renders, but nothing is ever composited, so no window
        // appears. The activation policy comes from Info.plist, which a bare
        // binary doesn't have — set it explicitly. In the Xcode build the
        // bundle already makes this .regular, so there it is a no-op. An app
        // that starts in the system tray is `.accessory` instead: no Dock
        // icon, no menus of its own.
        app.setActivationPolicy(showsDockIconAtLaunch ? .regular : .accessory)
        let delegate = AppDelegate(app: self)
        // NSApplication.delegate is weak — retain the delegate on self.
        appDelegate = delegate
        app.delegate = delegate
    }

    /// Show `item` in the system tray — the right end of the menu bar —
    /// until `removeTrayItem(_:)`. Call from `onStart()` or later.
    public func insertTrayItem(_ item: TrayItem) {
        appDelegate?.trayHost.insert(item)
    }

    /// Show what changed in an inserted tray item.
    public func refreshTrayItem(_ item: TrayItem) {
        appDelegate?.trayHost.refresh(item)
    }

    public func removeTrayItem(_ item: TrayItem) {
        appDelegate?.trayHost.remove(item)
    }
}

public final class AppDelegate<App: NucleantApplication>: NSObject, NSApplicationDelegate {
    
    weak var app: App?

    public let menuBarHost: AppKitMenuBar

    /// The app's items in the system tray.
    public let trayHost: AppKitTray
    
    @MainActor
    public init(app: App) {
        self.app = app
        self.menuBarHost = AppKitMenuBar()
        self.trayHost = AppKitTray()
        super.init()
    }
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        app?.onStart()
        // Bundle-less launches (see setup) come up unactivated, so the window
        // that onStart just presented would sit behind the terminal.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        app?.terminatesAfterLastWindowClosed ?? true
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        
    }
}



#endif
