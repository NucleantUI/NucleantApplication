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
