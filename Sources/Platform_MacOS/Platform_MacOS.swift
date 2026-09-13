//
//  Platform_MacOS.swift
//  NucleantApplication
//
#if os(macOS)
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
    // public so a conformance declared in another module (PyNucleantUI's
    // WindowBase) can use these as the default witnesses for the public
    // WindowBaseDelegate requirements — an internal default impl isn't
    // visible there and the conformance would fail to type-check.
    public func mouseDown(location: NSPoint) {
        on_mouse_down(x: location.x, y: location.y)
    }

    public func mouseUp(location: NSPoint) {
        on_mouse_up(x: location.x, y: location.y)
    }

    public func mouseDragged(location: NSPoint) {
        on_mouse_dragged(x: location.x, y: location.y)
    }

    public func mouseMoved(location: NSPoint) {
        on_mouse_moved(x: location.x, y: location.y)
    }

    public func rightMouseDown(location: NSPoint) {
        on_right_mouse_down(x: location.x, y: location.y)
    }

    public func rightMouseUp(location: NSPoint) {
        on_right_mouse_up(x: location.x, y: location.y)
    }

    public func scrollWheel(deltaX: Double, deltaY: Double) {
        on_scroll(dx: deltaX, dy: deltaY)
    }

    public func keyDown(key: UInt16, chars: String?) {
        on_key_down(keyCode: key, characters: chars)
    }

    public func keyUp(key: UInt16, chars: String?) {
        on_key_up(keyCode: key, characters: chars)
    }
    
    
    
    
}

public final class PlatformWindow<WindowBase>: NSWindow, NSWindowDelegate where WindowBase: NucleantWindow & WindowBaseDelegate {
    
    public var on_close:            (()->Void)?

    public weak var win_delegate: WindowBase?

    private var _displayLink: CVDisplayLink?

    public let metalLayer: CAMetalLayer
    
    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        let view = VulkanView(frame: .init(origin: .zero, size: contentRect.size))
        self.metalLayer = view.metalLayer
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.contentView = view
        self.delegate = self
        self.startDisplayLink()
    }
    
    public override func mouseDown(with event: NSEvent) {
        win_delegate?.mouseDown(location: event.locationInWindow)
    }
    
    public override func mouseUp(with event: NSEvent) {
        win_delegate?.mouseUp(location: event.locationInWindow)
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
        win_delegate?.rightMouseUp(location: event.locationInWindow)
    }
    
    public override func scrollWheel(with event: NSEvent) {
        // `deltaX/Y` are the *legacy line-based* deltas. A trackpad or Magic
        // Mouse sets `hasPreciseScrollingDeltas`, and for those `deltaY`
        // reports a fraction of a line — a whole two-finger drag adds up to a
        // few points, which reads as a scroll view that barely moves.
        //
        // `scrollingDeltaX/Y` is the value those devices actually report: in
        // points when the deltas are precise, in lines otherwise. So use it,
        // and convert lines to points for a classic wheel.
        let pointsPerLine = 16.0
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : pointsPerLine
        win_delegate?.scrollWheel(
            deltaX: Double(event.scrollingDeltaX) * scale,
            deltaY: Double(event.scrollingDeltaY) * scale
        )
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

    public func windowDidResize(_ notification: Notification) {
        // Report the content area (the render surface), not the whole window
        // frame — the root widget fills the content, matching present's
        // contentRect. The layer's drawableSize follows via VulkanView; this
        // drives the widget-tree relayout.
        guard let size = contentView?.bounds.size else { return }
        win_delegate?.on_size(w: Double(size.width), h: Double(size.height))
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
#endif



