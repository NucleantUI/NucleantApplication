//
//  NSView.swift
//  SulphurXcodeDemo
//
#if os(macOS)
import AppKit
import QuartzCore
import Metal

/// An NSView backed by a CAMetalLayer, suitable for MoltenVK VkSurface creation.
///
/// Wire up `onFrame` to your Vulkan render loop; it receives the display-link
/// delta time in seconds.  Pass `metalLayer` to vkCreateMetalSurfaceEXT.
public final class VulkanView: NSView {

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

    // MARK: - Resize

    /// Keep the Metal layer's pixel buffer in step with the view. The
    /// `autoresizingMask` only tracks the layer's *frame*, not its
    /// `drawableSize` (the render target's actual resolution) — so without
    /// this the surface stays the old size and the content stretches on
    /// resize. The engine reads `drawableSize` every frame and recreates its
    /// swapchain when it changes, so updating it here is what makes the render
    /// surface follow the window.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let metalLayer else { return }
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(
            width:  newSize.width  * metalLayer.contentsScale,
            height: newSize.height * metalLayer.contentsScale
        )
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
#endif


