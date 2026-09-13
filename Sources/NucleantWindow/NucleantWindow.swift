//
//  NucleantWindow.swift
//  NucleantApplication
//
import NucleantVulkan

public protocol NucleantWindow: AnyObject {
    //func on_build() throws -> NucleantWidgetBase?
    associatedtype Node: RenderContainerNode
    var renderEngine: VulkanRenderEngine<Node>? { get set }
    //var rootWidget: NucleantWidgetBase? { get set }
    
    var win_rect: SIMD4<Int> { get set }
    
    
    func present() throws

    func onFrame(_ dt: Double)
    //func on_frame(dt: Double)
    func on_size(w: Double, h: Double)

    /// Android only: the platform layer has just rebuilt `renderEngine` from
    /// scratch against a genuinely new native window — as opposed to the
    /// existing window merely changing size — because the old one is no
    /// longer valid (e.g. the Activity's Surface was destroyed and recreated
    /// across a minimize/resume). The fresh engine has an empty node list, so
    /// conformers must re-bind whatever they last bound into the old one.
    /// Default is a no-op so platforms that never rebuild the engine under
    /// them (everywhere but Android) are unaffected.
    func on_surface_recreated()

    func on_mouse_down(x: Double, y: Double)
    func on_mouse_up(x: Double, y: Double)
    func on_mouse_dragged(x: Double, y: Double)
    func on_mouse_moved(x: Double, y: Double)
    func on_right_mouse_down(x: Double, y: Double)
    func on_right_mouse_up(x: Double, y: Double)
    func on_scroll(dx: Double, dy: Double)
    func on_key_down(keyCode: UInt16, characters: String?)
    func on_key_up(keyCode: UInt16, characters: String?)

    // Touch input (iOS). `id` is a per-window stable identifier for one finger,
    // handed out by the platform layer for the lifetime of a touch sequence so
    // multitouch gestures can be tracked across down → moved → up. Coordinates
    // are in the same content space as the mouse callbacks.
    func on_touch_down(id: Int, x: Double, y: Double)
    func on_touch_moved(id: Int, x: Double, y: Double)
    func on_touch_up(id: Int, x: Double, y: Double)
    func on_touch_cancelled(id: Int, x: Double, y: Double)
}

// Default no-op touch handlers so conformers that don't care about touch (e.g.
// the macOS mouse/keyboard windows) stay unaffected; each platform's window
// overrides only what it uses.
public extension NucleantWindow {
    func on_touch_down(id: Int, x: Double, y: Double) {}
    func on_touch_moved(id: Int, x: Double, y: Double) {}
    func on_touch_up(id: Int, x: Double, y: Double) {}
    func on_touch_cancelled(id: Int, x: Double, y: Double) {}
    func on_surface_recreated() {}
}

