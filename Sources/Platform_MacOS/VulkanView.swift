//
//  NSView.swift
//  SulphurXcodeDemo
//
import AppKit
import QuartzCore
import Metal

/// An NSView backed by a CAMetalLayer, suitable for MoltenVK VkSurface creation.
///
/// Wire up `onFrame` to your Vulkan render loop; it receives the display-link
/// delta time in seconds.  Pass `metalLayer` to vkCreateMetalSurfaceEXT.
public final class DemoNSView: NSView {

    /// The Metal layer MoltenVK uses for VkSurface creation.
    public private(set) var metalLayer: CAMetalLayer!

    private var _displayLink: CVDisplayLink?

    // MARK: - Init

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        let ml = CAMetalLayer()
        ml.device           = MTLCreateSystemDefaultDevice()
        ml.pixelFormat      = .bgra8Unorm
        ml.framebufferOnly  = false
        ml.frame            = bounds
        ml.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer      = ml
        metalLayer = ml
    }

    public override func makeBackingLayer() -> CALayer {
        let ml = CAMetalLayer()
        ml.device          = MTLCreateSystemDefaultDevice()
        ml.pixelFormat     = .bgra8Unorm
        ml.framebufferOnly = false
        return ml
    }
    
    // MARK: - Input events

    public override var acceptsFirstResponder: Bool { true }

    private var trackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    
}


