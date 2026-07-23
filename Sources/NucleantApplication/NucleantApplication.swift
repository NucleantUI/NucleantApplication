// The Swift Programming Language
// https://docs.swift.org/swift-book
import NucleantWindow

@MainActor
public protocol NucleantApplication: AnyObject {
    
    func onStart()
    
    func setup()
    
    
    
    
    
    #if os(macOS)
    var appDelegate: AppDelegate<Self>? { get set }
    #endif
}
