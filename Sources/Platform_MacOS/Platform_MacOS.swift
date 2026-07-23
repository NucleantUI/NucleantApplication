//
//  Platform_MacOS.swift
//  NucleantApplication
//


import AppKit


protocol WindowBaseDelegate: AnyObject {
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



public final class PlatformWindow: NSWindow, NSWindowDelegate {
    
    public var on_close:            (()->Void)?
    
    weak var win_delegate: WindowBase?
    
    private var _displayLink: CVDisplayLink?
    
    let metalLayer: CAMetalLayer
    
    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        let view = DemoNSView(frame: .init(origin: .zero, size: contentRect.size))
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
            startCVDisplayLink()
        }
    }
    
    public func stopDisplayLink() {
        if let dl = _displayLink {
            CVDisplayLinkStop(dl)
            _displayLink = nil
        }
    }
    
}



// MARK: - CVDisplayLink (macOS < 14)

//@available(macOS, introduced: 10.4, obsoleted: 14.0)
// ^ original annotation — `obsoleted` stops compiling under the macOS 14
// deployment floor (Observation), so `deprecated` stands in below. The
// whole CVDisplayLink path stays intact for a future pre-14 build.
@available(macOS, introduced: 10.4, deprecated: 14.0)
private extension PlatformWindow {
    func startCVDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let link = dl , let win_delegate else { return }
        _displayLink = link

        let ref = Unmanaged.passUnretained(win_delegate)
        CVDisplayLinkSetOutputCallback(link, { _, _, outputTime, _, _, ctx -> CVReturn in
            guard let ctx else { return kCVReturnError }
            let ot = outputTime.pointee
            let dt = Double(ot.videoRefreshPeriod) / Double(ot.videoTimeScale)
            let win = Unmanaged<WindowBase>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { win.onFrame(dt) }
            return kCVReturnSuccess
        }, ref.toOpaque())

        CVDisplayLinkStart(link)
    }
}

// MARK: - CADisplayLink (macOS 14+)

@available(macOS 14.0, *)
private extension PlatformWindow {
    func startCADisplayLink() {
        let link = displayLink(target: self, selector: #selector(cadlTick(_:)))
        link.add(to: .main, forMode: .common)
    }

    @objc func cadlTick(_ link: CADisplayLink) {
        win_delegate?.onFrame(link.targetTimestamp - link.timestamp)
    }
}

