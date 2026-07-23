//
//  Platform_MacOS.swift
//  NucleantApplication
//
import NucleantWindow

import AppKit


public protocol WindowBaseDelegate: AnyObject {
    func mouseDown(location: NSPoint)
    func mouseUp(location: NSPoint)
    func mouseDragged(location: NSPoint)
    func mouseMoved(location: NSPoint)
    func rightMouseDown(location: NSPoint)
    func rightMouseUp(location: NSPoint)
    func scrollWheel(deltaX: Double, deltaY: Double)
    func keyDown(key: UInt16, chars:  String?)
    func keyUp(key: UInt16, chars:  String?)
}

extension NucleantWindow where Self: WindowBaseDelegate {
    func mouseDown(location: NSPoint) {
        on_mouse_down(x: location.x, y: location.y)
    }
    
    func mouseUp(location: NSPoint) {
        on_mouse_up(x: location.x, y: location.y)
    }
    
    func mouseDragged(location: NSPoint) {
        on_mouse_dragged(x: location.x, y: location.y)
    }
    
    func mouseMoved(location: NSPoint) {
        on_mouse_moved(x: location.x, y: location.y)
    }
    
    func rightMouseDown(location: NSPoint) {
        on_right_mouse_down(x: location.x, y: location.y)
    }
    
    func rightMouseUp(location: NSPoint) {
        on_right_mouse_up(x: location.x, y: location.y)
    }
    
    func scrollWheel(deltaX: Double, deltaY: Double) {
        on_scroll(dx: deltaX, dy: deltaY)
    }
    
    func keyDown(key: UInt16, chars: String?) {
        on_key_down(keyCode: key, characters: chars)
    }
    
    func keyUp(key: UInt16, chars: String?) {
        on_key_up(keyCode: key, characters: chars)
    }
    
    
    
    
}

public final class PlatformWindow<WindowBase>: NSWindow, NSWindowDelegate where WindowBase: NucleantWindow & WindowBaseDelegate {
    
    public var on_close:            (()->Void)?
    
    weak var win_delegate: WindowBase?
    
    private var _displayLink: CVDisplayLink?
    
    let metalLayer: CAMetalLayer
    
    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        let view = VulkanView(frame: .init(origin: .zero, size: contentRect.size))
        self.metalLayer = view.metalLayer
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.contentView = view
        self.startDisplayLink()
    }
    
    public override func mouseDown(with event: NSEvent) {
        win_delegate?.mouseDown(location: event.locationInWindow)
    }
    
    public override func mouseUp(with event: NSEvent) {
        win_delegate?.mouseDown(location: event.locationInWindow)
    }
    
    public override func mouseDragged(with event: NSEvent) {
        win_delegate?.mouseDragged(location: event.locationInWindow)
    }
    
    public override func mouseMoved(with event: NSEvent) {
        win_delegate?.mouseMoved(location: event.locationInWindow)
    }
    
    public override func rightMouseDown(with event: NSEvent) {
        win_delegate?.rightMouseDown(location: event.locationInWindow)
    }
    
    public override func rightMouseUp(with event: NSEvent) {
        win_delegate?.rightMouseDown(location: event.locationInWindow)
    }
    
    public override func scrollWheel(with event: NSEvent) {
        win_delegate?.scrollWheel(deltaX: event.deltaX, deltaY: event.deltaY)
    }
    
    public override func keyDown(with event: NSEvent) {
        win_delegate?.keyDown(key: event.keyCode, chars: event.characters)
    }
    
    public override func keyUp(with event: NSEvent) {
        win_delegate?.keyUp(key: event.keyCode, chars: event.characters)
    }
    
    
    
    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        
        return frameSize
    }
    
    
    public func windowDidMiniaturize(_ notification: Notification) {
        
    }
    
    public func windowDidBecomeKey(_ notification: Notification) {
        
    }
    
    public func startDisplayLink() {
        if #available(macOS 14.0, *) {
            startCADisplayLink()
        } else {
            //startCVDisplayLink()
        }
    }
    
    public func stopDisplayLink() {
        if let dl = _displayLink {
            CVDisplayLinkStop(dl)
            _displayLink = nil
        }
    }
    
    func startCADisplayLink() {
        let link = displayLink(target: self, selector: #selector(cadlTick(_:)))
        link.add(to: .main, forMode: .common)
    }

    @objc func cadlTick(_ link: CADisplayLink) {
        win_delegate?.onFrame(link.targetTimestamp - link.timestamp)
    }
}



