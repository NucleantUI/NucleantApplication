//
//  VulkanView.swift
//  NucleantApplication
//
#if os(iOS)
import UIKit
import QuartzCore
import Metal

/// A UIView whose backing layer *is* a CAMetalLayer, suitable for MoltenVK
/// VkSurface creation. The iOS analogue of the macOS `VulkanView`: pass
/// `metalLayer` to vkCreateMetalSurfaceEXT. Input, the display link, and size
/// reporting are owned by `PlatformWindow` (mirroring macOS, where `VulkanView`
/// is likewise just the Metal surface and `NSWindow` handles everything else).
public final class VulkanView: UIView {

    /// Backing layer is the CAMetalLayer — no separate layer to manage.
    public override class var layerClass: AnyClass { CAMetalLayer.self }

    /// The Metal layer MoltenVK uses for VkSurface creation.
    public var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isMultipleTouchEnabled = true
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let ml = metalLayer
        ml.device          = MTLCreateSystemDefaultDevice()
        ml.pixelFormat     = .bgra8Unorm
        ml.framebufferOnly = false
        ml.contentsScale   = scale
    }

    // MARK: - Resize

    /// Keep the Metal layer's pixel buffer in step with the view. `layoutSubviews`
    /// is UIKit's resize hook (bounds/rotation changes land here). The engine
    /// reads `drawableSize` every frame and recreates its swapchain when it
    /// changes, so updating it here is what makes the render surface follow the
    /// view.
    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? contentScaleFactor
        let ml = metalLayer
        ml.contentsScale = scale
        ml.drawableSize = CGSize(
            width:  bounds.width  * scale,
            height: bounds.height * scale
        )
    }
}
#endif
