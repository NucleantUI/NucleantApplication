//
//  AndroidSurfaceHost.swift
//  NucleantApplication
//
#if os(Android)
import Foundation

/// Receives the app's render surface and input from the Android edge.
///
/// `AndroidSurfaceBridge` in this same module is the other half: the Activity's
/// SurfaceView hands it an `android.view.Surface`, it turns that into an
/// `ANativeWindow *`, and calls the entry points below directly.
///
/// It used to be reached by `dlsym`. The bridge was generated into each app's
/// own Swift package, which the Python bootstrap loaded before this library
/// existed, so the two had no link-time relationship and a C ABI was the only
/// thing that could cross — and every surface event that fired before this
/// library loaded was dropped, which `nucleant_refresh_host_hooks` existed to
/// replay. Python is gone, the native side is one binary, and the bridge is in
/// this module: there is no window during which these are absent, so there is
/// nothing to look up and nothing to replay.
public enum AndroidSurfaceHost {

    /// The live surface, or nil between destroy and the next create (app
    /// backgrounded, device rotated).
    ///
    /// Written from the UI thread and read from the render thread, so every
    /// access takes the lock — a torn read is a use-after-free of a window the
    /// system has already reclaimed.
    public nonisolated(unsafe) private(set) static var window: OpaquePointer?
    /// Surface size in physical pixels. Android is always fullscreen, so this
    /// *is* the window size rather than a request — the counterpart of iOS
    /// building its UIWindow from the scene.
    public nonisolated(unsafe) private(set) static var width: Int = 0
    public nonisolated(unsafe) private(set) static var height: Int = 0

    private static let lock = NSLock()

    /// Called when a surface becomes available, and again after every
    /// rotation/resize. Set by the platform window so it can build or rebuild
    /// its engine; the bridge reaches it through `surfaceCreated`/`surfaceResized`
    /// rather than setting it.
    public nonisolated(unsafe) static var onSurfaceChanged: ((OpaquePointer?, Int, Int) -> Void)?
    /// Called before the surface goes away. Must not return until the renderer
    /// has stopped touching the window — the Surface is only guaranteed valid
    /// until then.
    public nonisolated(unsafe) static var onSurfaceDestroyed: (() -> Void)?

    /// Input, forwarded to whichever window is on screen.
    public nonisolated(unsafe) static var onTouch: ((TouchPhase, Int, Double, Double) -> Void)?
    public nonisolated(unsafe) static var onKey: ((Bool, Int, Int) -> Void)?
    public nonisolated(unsafe) static var onActiveChanged: ((Bool) -> Void)?
    /// Draw one frame. Called from the Activity's Choreographer callback, on
    /// the UI thread — which is the process main thread, so unlike the render
    /// thread this once had, main-actor isolation here is true rather than
    /// asserted.
    public nonisolated(unsafe) static var onFrame: ((Double) -> Void)?

    /// Backing-store pixels per point, from the display.
    ///
    /// Android reports this as `DisplayMetrics.density`, which only Java can
    /// read, so the Activity hands it over before the app starts. 1 until it
    /// does — a wrong-but-defined value rather than a guess, and on a device
    /// it is always set before the first layout.
    public nonisolated(unsafe) static var displayScale: Double = 1

    public enum TouchPhase: Int32 {
        case down = 0, moved = 1, up = 2, cancelled = 3
    }

    private static func setSurface(_ w: OpaquePointer?, _ width: Int, _ height: Int) {
        lock.lock()
        Self.window = w
        Self.width = width
        Self.height = height
        lock.unlock()
    }

    public static func currentSurface() -> (OpaquePointer?, Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (window, width, height)
    }

    // MARK: - Called by AndroidSurfaceBridge

    /// A surface became available, or a new one replaced the old.
    public static func surfaceCreated(_ window: OpaquePointer?, _ w: Int, _ h: Int) {
        setSurface(window, w, h)
        onSurfaceChanged?(window, w, h)
    }

    /// Rotation or resize. Unlike `surfaceCreated` this always re-delivers the
    /// window the host already has, which is what lets `PlatformWindow` tell a
    /// plain resize apart from a genuinely new surface.
    public static func surfaceResized(_ w: Int, _ h: Int) {
        let (window, _, _) = currentSurface()
        setSurface(window, w, h)
        onSurfaceChanged?(window, w, h)
    }

    /// The surface is going away. Returns once the renderer has stopped
    /// touching it — the Surface is only guaranteed valid until the Java-side
    /// callback returns, so the view blocks on this.
    public static func surfaceDestroyed() {
        onSurfaceDestroyed?()
        setSurface(nil, 0, 0)
    }

    // MARK: - First frame

    /// Whether a frame has reached the surface, so the Activity knows when to
    /// take its presplash down. Set by `PlatformWindow` on the first frame it
    /// draws; read through `nucleantFirstFrameRendered()`.
    ///
    /// Written on the render path and read from the looper, so both sides take
    /// the lock.
    public static var firstFrameRendered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _firstFrameRendered
    }

    static func markFirstFrame() {
        lock.lock()
        _firstFrameRendered = true
        lock.unlock()
    }

    private nonisolated(unsafe) static var _firstFrameRendered = false
}
#endif
