//
//  PlatformWindow.swift
//  NucleantApplication
//
#if os(iOS)
import NucleantWindow
import UIKit
import QuartzCore

/// The iOS counterpart to macOS's `PlatformWindow`: a `UIWindow` hosting a
/// `VulkanView` through a root view controller. Mirrors macOS exactly — the
/// window itself owns the display link and overrides touch handling directly,
/// forwarding straight to `win_delegate` with no closure/callback indirection.
/// Kept generic (not existential) for the same reason as macOS — `NucleantWindow`
/// has an associated `Node`, so a concrete `WindowBase` type is needed to call
/// its members.
public final class PlatformWindow<WindowBase>: UIWindow, UIWindowSceneDelegate
    where WindowBase: NucleantWindow & WindowTouchDelegate {

    public var on_close: (() -> Void)?

    /// Strongly-held by the owner (PyNucleantUI keeps this); we only reference
    /// it weakly so the window doesn't retain its delegate.
    public weak var win_delegate: WindowBase?

    private let vulkanView: VulkanView
    private let rootVC: UIViewController

    private var displayLink: CADisplayLink?

    /// Per-window stable touch ids: UIKit hands out UITouch objects, not
    /// indices, so map each active touch to a small integer for the lifetime
    /// of its sequence.
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0

    /// The Metal layer to hand to `VulkanRenderEngine(metalLayer:)`.
    public var metalLayer: CAMetalLayer { vulkanView.metalLayer }

    public override init(frame: CGRect) {
        let view = VulkanView(frame: frame)
        self.vulkanView = view
        let vc = UIViewController()
        self.rootVC = vc
        super.init(frame: frame)
        vc.view = view
        self.rootViewController = vc
        startDisplayLink()
    }

    /// Attaches to a real `UIWindowScene` instead of a bare frame — this is
    /// what makes the window track Stage Manager resizing automatically
    /// (the OS keeps a scene-owned window's frame in step with
    /// `windowScene.coordinateSpace.bounds`); a frame-only window never
    /// resizes on its own.
    public override init(windowScene: UIWindowScene) {
        let bounds = windowScene.coordinateSpace.bounds
        let view = VulkanView(frame: bounds)
        self.vulkanView = view
        let vc = UIViewController()
        self.rootVC = vc
        super.init(windowScene: windowScene)
        self.frame = bounds
        vc.view = view
        self.rootViewController = vc
        startDisplayLink()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry) {
        let screen = windowScene.screen
        let rect = screen.bounds
        let scale = screen.scale
        win_delegate?.on_size(w: rect.width * scale, h: rect.height * scale)
    }

    // MARK: - Resize

    /// Report the content area (the render surface), not any status-bar
    /// inset — the root widget fills the content, matching present's
    /// contentRect. The layer's drawableSize follows via VulkanView; this
    /// drives the widget-tree relayout. Mirrors macOS's `windowDidResize`.
    public override func layoutSubviews() {
        super.layoutSubviews()
        win_delegate?.on_size(w: Double(bounds.width), h: Double(bounds.height))
    }

    // MARK: - Display link

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(cadlTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func cadlTick(_ link: CADisplayLink) {
        win_delegate?.onFrame(link.targetTimestamp - link.timestamp)
    }

    // MARK: - Touch input

    private func id(for touch: UITouch) -> Int {
        let key = ObjectIdentifier(touch)
        if let existing = touchIDs[key] { return existing }
        let assigned = nextTouchID
        nextTouchID &+= 1
        touchIDs[key] = assigned
        return assigned
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            win_delegate?.touchDown(id: id(for: touch), location: touch.location(in: self))
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            win_delegate?.touchMoved(id: id(for: touch), location: touch.location(in: self))
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let tid = id(for: touch)
            win_delegate?.touchUp(id: tid, location: touch.location(in: self))
            touchIDs[ObjectIdentifier(touch)] = nil
        }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let tid = id(for: touch)
            win_delegate?.touchCancelled(id: tid, location: touch.location(in: self))
            touchIDs[ObjectIdentifier(touch)] = nil
        }
    }
}
#endif
