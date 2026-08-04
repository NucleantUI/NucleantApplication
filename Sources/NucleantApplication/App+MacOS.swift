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
        // bundle already makes this .regular, so there it is a no-op.
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(app: self)
        // NSApplication.delegate is weak — retain the delegate on self.
        appDelegate = delegate
        app.delegate = delegate
    }
}

public final class AppDelegate<App: NucleantApplication>: NSObject, NSApplicationDelegate {
    
    weak var app: App?
    
    public init(app: App) {
        self.app = app
        super.init()
    }
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        app?.onStart()
        // Bundle-less launches (see setup) come up unactivated, so the window
        // that onStart just presented would sit behind the terminal.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    
    public func applicationWillTerminate(_ notification: Notification) {
        
    }
}



#endif
