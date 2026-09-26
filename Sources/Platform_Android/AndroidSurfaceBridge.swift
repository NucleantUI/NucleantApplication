//
//  AndroidSurfaceBridge.swift
//  NucleantApplication
//
//  The Android surface, input and lifecycle edge — everything between
//  `android.view.Surface` and `AndroidSurfaceHost`.
//
//  This was generated into each app's Swift package as `AndroidSurface.swift`,
//  one module away from the `AndroidSurfaceHost` it drives. Nothing about it is
//  app-specific, and the split had a cost: two modules with no link-time
//  relationship can only meet over a C ABI, so every hook was reached by dlsym
//  and a surface that arrived before the other half loaded was dropped —
//  `nucleant_refresh_host_hooks` existed to replay it. In one module that gap
//  cannot open, and the calls are ordinary Swift.
//
//  What still lives in the app's generated package is the *Java* edge: jextract
//  reads syntax and has to sit on the target holding the `public func`s it
//  exports. Those are one-line forwards into this file.
//
#if os(Android)
import Android
import CAndroidNativeWindow
import Foundation
import SwiftJava

// MARK: - Logging

/// Logcat, for the handful of lines this file emits.
///
/// Foundation's `print` goes to stdout, which on Android goes nowhere unless
/// something has redirected it — so the bridge's own diagnostics use the
/// platform logger directly rather than relying on that redirection existing.
public func nucleantLog(_ message: String) {
    __android_log_write(4 /* ANDROID_LOG_INFO */, "nucleant", message)
}

public func nucleantLogError(_ message: String) {
    __android_log_write(6 /* ANDROID_LOG_ERROR */, "nucleant", message)
}

/// Point stdout and stderr at logcat.
///
/// Anything the Swift graph or its C dependencies print — ThorVG's engine
/// diagnostics, wgpu's validation messages — is otherwise written to
/// descriptors Android discards. A pipe per descriptor, drained by a thread
/// that forwards each line to the log, is the same trick the Python bootstrap
/// used and is worth keeping: those messages are most of what a device-side
/// failure has to say for itself.
public func nucleantRedirectFDs() {
    for (fd, priority) in [(1, Int32(4)), (2, Int32(6))] {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { continue }
        dup2(fds[1], Int32(fd))
        close(fds[1])

        let readEnd = fds[0]
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var pending = ""
            while true {
                let n = read(readEnd, &buffer, buffer.count)
                if n <= 0 { break }
                pending += String(decoding: buffer[0..<n], as: UTF8.self)
                while let newline = pending.firstIndex(of: "\n") {
                    let line = String(pending[pending.startIndex..<newline])
                    pending = String(pending[pending.index(after: newline)...])
                    __android_log_write(priority, "nucleant", line)
                }
            }
        }
        thread.stackSize = 1 << 19
        thread.start()
    }
}

// MARK: - The window

/// The live window, retained for as long as the Surface is valid.
///
/// `ANativeWindow_fromSurface` returns a +1 reference, so releasing it is this
/// file's job — and it must not happen until the renderer has stopped touching
/// it, which is what the ordering in `nucleantSurfaceDestroyed` is about.
///
/// `ANativeWindow` is an opaque struct in the NDK headers, so Swift imports
/// every reference to it as `OpaquePointer` — there is no typed pointer to
/// convert to or from, here or in `AndroidSurfaceHost`.
private nonisolated(unsafe) var nativeWindow: OpaquePointer?
private let windowLock = NSLock()

// MARK: - Surface lifecycle

/// `SurfaceHolder.Callback.surfaceCreated`.
///
/// `ANativeWindow_fromSurface` takes the raw JNIEnv/jobject pair, which is
/// exactly what a swift-java `JavaObject` carries — so the Surface crosses as
/// one and nothing here has to launder pointers. That is the whole reason this
/// package depends on swift-java's runtime product; jextract, which is the part
/// that wants a JDK, stays in the app's own package.
public func nucleantAttachSurface(surface: JavaObject) {
    guard let window = ANativeWindow_fromSurface(
        surface.javaEnvironment,
        surface.javaThis
    ) else {
        nucleantLogError("ANativeWindow_fromSurface returned null")
        return
    }
    windowLock.lock()
    let previous = nativeWindow
    nativeWindow = window
    windowLock.unlock()
    if let previous { ANativeWindow_release(previous) }

    let width = ANativeWindow_getWidth(window)
    let height = ANativeWindow_getHeight(window)
    nucleantLog("surface created \(width)x\(height)")
    AndroidSurfaceHost.surfaceCreated(window, Int(width), Int(height))
}

/// `SurfaceHolder.Callback.surfaceChanged` — rotation, resize, and the initial
/// size report that always follows surfaceCreated.
///
/// An Android app is always fullscreen, so this size is the window size, not a
/// request. Whatever size the app's window was constructed with is overridden
/// here, the same way iOS builds its UIWindow from the scene.
public func nucleantSurfaceResized(width: Int32, height: Int32) {
    nucleantLog("surface changed \(width)x\(height)")
    AndroidSurfaceHost.surfaceResized(Int(width), Int(height))
}

/// `SurfaceHolder.Callback.surfaceDestroyed`. Returns once the renderer has
/// stopped touching the window: the Surface is only guaranteed valid until this
/// call returns, so the view blocks on it.
public func nucleantSurfaceDestroyed() {
    AndroidSurfaceHost.surfaceDestroyed()

    windowLock.lock()
    let window = nativeWindow
    nativeWindow = nil
    windowLock.unlock()
    if let window { ANativeWindow_release(window) }
    nucleantLog("surface destroyed")
}

// MARK: - First frame

/// Whether a frame has reached the surface. Java-facing — the Activity polls
/// this to decide when to take the presplash down.
///
/// Polled rather than pushed because jextract generates the Java -> Swift
/// direction only, and calling up into the Activity from the render thread would
/// mean a global ref plus AttachCurrentThread by hand. The Activity is already
/// on a looper, so letting it ask is far less machinery.
public func nucleantFirstFrameRendered() -> Bool {
    AndroidSurfaceHost.firstFrameRendered
}

// MARK: - Input

public func nucleantTouch(phase: Int32, pointerId: Int32, x: Float, y: Float) {
    guard let phase = AndroidSurfaceHost.TouchPhase(rawValue: phase) else { return }
    AndroidSurfaceHost.onTouch?(phase, Int(pointerId), Double(x), Double(y))
}

public func nucleantKey(down: Bool, keyCode: Int32, unicodeChar: Int32) {
    AndroidSurfaceHost.onKey?(down, Int(keyCode), Int(unicodeChar))
}

// MARK: - Display

/// The display's scale factor — `DisplayMetrics.density`.
///
/// Only Java can read it, and the layout needs it to turn the surface's pixel
/// size into points, so the Activity sends it before the app starts.
public func nucleantSetDisplayScale(_ scale: Double) {
    if scale > 0 { AndroidSurfaceHost.displayScale = scale }
}

// MARK: - Frames

/// Draw one frame. Called from the Activity's Choreographer callback.
///
/// The Activity is the frame source, the way it is in any Android app. This runs
/// on the UI thread — the process main thread — so the renderer's main-actor
/// isolation is simply true here, rather than something asserted from a thread
/// it was never on.
public func nucleantDrawFrame(dt: Double) {
    AndroidSurfaceHost.onFrame?(dt)
}

// MARK: - Activity lifecycle

/// The render loop starts and stops with these, so a backgrounded app costs no
/// frames.
public func nucleantSetActive(_ active: Bool) {
    AndroidSurfaceHost.onActiveChanged?(active)
}

/// `Activity.onDestroy()` — the Activity is gone for good, not backgrounded.
///
/// Nothing to unwind: with no interpreter to finalize, the app's teardown is the
/// process going away. The surface is already released by
/// `nucleantSurfaceDestroyed`, which Android always delivers first.
public func nucleantOnDestroy() {
    AndroidSurfaceHost.onActiveChanged?(false)
    nucleantLog("activity destroyed")
}
#endif
