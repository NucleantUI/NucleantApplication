//
//  NucleantBridge.swift
//  NucleantApplication
//
//  The Java edge for surface, input and lifecycle.
//
//  jextract turns every `public func` here into a static method on
//  `org.nucleantui.NucleantBridge`, and compiles the JNI glue into whichever
//  library this module is linked into — `libNucleantMain.so`, the app's one
//  binary. `NucleantActivity` and `NucleantSurfaceView`, which ship beside this
//  file under `Android/java`, are what call them.
//
//  Every body is a forward into `Platform_Android`, where the work lives. These
//  declarations exist only because jextract reads *syntax*: it generates Java
//  for the `public func`s in the target its plugin is attached to, and nowhere
//  else. That is the one reason this is a module of its own rather than more
//  functions in Platform_Android — the plugin would otherwise run over that
//  whole target, including everything that has no business crossing to Java.
//
//  What is *not* here is the app's entry point. `nucleantRunMain` has to build
//  the app's `NucleantApp` type, which lives above this package in
//  NucleantSwiftUI, so it is generated into the app's own Swift target and
//  reached through `NucleantActivity.startApp`.
//
#if os(Android)
import Platform_Android
import SwiftJava

// MARK: - Surface lifecycle

/// `SurfaceHolder.Callback.surfaceCreated`.
public func nucleantSurfaceCreated(surface: JavaObject) {
    nucleantAttachSurface(surface: surface)
}

/// `SurfaceHolder.Callback.surfaceChanged` — rotation, resize, and the initial
/// size report that always follows surfaceCreated.
public func nucleantSurfaceChanged(width: Int32, height: Int32) {
    nucleantSurfaceResized(width: width, height: height)
}

/// `SurfaceHolder.Callback.surfaceDestroyed`. Returns once the renderer has
/// stopped touching the window, so the view can block on it.
public func nucleantSurfaceDestroyed() {
    Platform_Android.nucleantSurfaceDestroyed()
}

/// Whether a frame has reached the surface — the Activity polls this to decide
/// when to take the presplash down.
public func nucleantFirstFrameRendered() -> Bool {
    Platform_Android.nucleantFirstFrameRendered()
}

// MARK: - Input
//
// Phase values mirror `AndroidSurfaceHost.TouchPhase`.

public func nucleantTouchDown(pointerId: Int32, x: Float, y: Float) {
    nucleantTouch(phase: 0, pointerId: pointerId, x: x, y: y)
}

public func nucleantTouchMoved(pointerId: Int32, x: Float, y: Float) {
    nucleantTouch(phase: 1, pointerId: pointerId, x: x, y: y)
}

public func nucleantTouchUp(pointerId: Int32, x: Float, y: Float) {
    nucleantTouch(phase: 2, pointerId: pointerId, x: x, y: y)
}

public func nucleantTouchCancelled(pointerId: Int32, x: Float, y: Float) {
    nucleantTouch(phase: 3, pointerId: pointerId, x: x, y: y)
}

public func nucleantKeyDown(keyCode: Int32, unicodeChar: Int32) {
    nucleantKey(down: true, keyCode: keyCode, unicodeChar: unicodeChar)
}

public func nucleantKeyUp(keyCode: Int32, unicodeChar: Int32) {
    nucleantKey(down: false, keyCode: keyCode, unicodeChar: unicodeChar)
}

// MARK: - Display and frames

/// The display's scale factor — `DisplayMetrics.density`. Only Java can read it,
/// and the layout needs it to turn the surface's pixel size into points, so the
/// Activity sends it before the app starts.
public func nucleantSetDisplayScale(scale: Double) {
    Platform_Android.nucleantSetDisplayScale(scale)
}

/// Draw one frame. Called from the Activity's Choreographer callback, on the UI
/// thread — the process main thread, so the renderer's main-actor isolation is
/// simply true here rather than asserted.
public func nucleantDrawFrame(dt: Double) {
    Platform_Android.nucleantDrawFrame(dt: dt)
}

// MARK: - Activity lifecycle
//
// The render loop starts and stops with these, so a backgrounded app costs no
// frames.

public func nucleantOnResume() {
    nucleantSetActive(true)
}

public func nucleantOnPause() {
    nucleantSetActive(false)
}

/// `Activity.onDestroy()` — the Activity is gone for good, not backgrounded.
public func nucleantOnDestroy() {
    Platform_Android.nucleantOnDestroy()
}

// MARK: - Startup support

/// Point stdout and stderr at logcat, and log a line.
///
/// Called by the app's generated entry before it starts the runtime; exposed
/// here so that file has nothing in it but the app's own type.
public func nucleantPrepareProcess(appPath: String) {
    nucleantRedirectFDs()
    nucleantLog("starting app; appPath=\(appPath)")
}
#endif
