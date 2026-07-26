// The Swift Programming Language
// https://docs.swift.org/swift-book
import NucleantWindow

@MainActor
public protocol NucleantApplication: AnyObject {
    
    func onStart()
    
    func setup()
    
    
    
    
    
    #if os(macOS) || os(iOS)
    // Each platform compiles its own `AppDelegate` type (NSApplicationDelegate
    // on macOS, UIApplicationDelegate on iOS) — only one is in scope per build,
    // so `AppDelegate<Self>` resolves unambiguously.
    var appDelegate: AppDelegate<Self>? { get set }
    #endif
}
