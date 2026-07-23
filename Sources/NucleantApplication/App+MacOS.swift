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
    }
    
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    
    public func applicationWillTerminate(_ notification: Notification) {
        
    }
}



#endif
