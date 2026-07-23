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
    func on_mouse_down(x: Double, y: Double)
    func on_mouse_up(x: Double, y: Double)
    func on_mouse_dragged(x: Double, y: Double)
    func on_mouse_moved(x: Double, y: Double)
    func on_right_mouse_down(x: Double, y: Double)
    func on_right_mouse_up(x: Double, y: Double)
    func on_scroll(dx: Double, dy: Double)
    func on_key_down(keyCode: UInt16, characters: String?)
    func on_key_up(keyCode: UInt16, characters: String?)
}

