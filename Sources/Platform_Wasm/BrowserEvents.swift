//
//  BrowserEvents.swift
//  NucleantApplication
//
//  How the page gets into wasm: functions exported from the module, which
//  Web/nucleant-app.js calls from requestAnimationFrame and from the DOM
//  event listeners of each window's canvas. The counterpart of the
//  compositor callbacks on Linux and of AppKit's event dispatch on macOS —
//  each finds its window by id and hands the event to it.
//
#if os(WASI)
import CWasmDOM

// MARK: - Frame loop

/// Observers of the page's display refresh, for code that wants a per-frame
/// tick without owning a window — NucleantSync's display-synced callbacks.
/// The parallel of Linux's `FrameLoopTurn`; every observer and every ticking
/// window rides the same requestAnimationFrame loop, which runs while any of
/// them wants it.
public enum BrowserFrameLoop {

    private nonisolated(unsafe) static var observers: [Int: (Double) -> Void] = [:]
    private nonisolated(unsafe) static var nextID = 0
    private nonisolated(unsafe) static var running = false

    /// Calls `observer` with the frame's timestamp, in seconds, on every
    /// display refresh. Returns the id to hand to `remove(_:)`.
    public static func add(_ observer: @escaping (Double) -> Void) -> Int {
        let id = nextID
        nextID += 1
        observers[id] = observer
        update()
        return id
    }

    public static func remove(_ id: Int) {
        observers[id] = nil
        update()
    }

    /// Runs the loop exactly while an observer or a ticking window exists.
    static func update() {
        let wanted = !observers.isEmpty || BrowserWindow.all.contains { $0.ticking }
        guard wanted != running else { return }
        running = wanted
        if wanted {
            nwd_frame_loop_start()
        } else {
            nwd_frame_loop_stop()
        }
    }

    static func fire(now: Double) {
        guard !observers.isEmpty else { return }
        // An observer may add or remove observers while running.
        for observer in Array(observers.values) {
            observer(now)
        }
    }
}

/// One display refresh: `timestamp` is requestAnimationFrame's, in
/// milliseconds.
@_expose(wasm, "nucleant_frame")
public func nucleantFrame(_ timestamp: Double) {
    let now = timestamp / 1000
    BrowserFrameLoop.fire(now: now)
    for window in BrowserWindow.all {
        window.frame(at: now)
    }
}

// MARK: - Window events

@_expose(wasm, "nucleant_window_resized")
public func nucleantWindowResized(_ window: UInt32) {
    BrowserWindow.window(window)?.resized()
}

/// Pointer phases and types, as the page encodes them.
enum BrowserPointer {
    static let down: UInt32 = 0
    static let up: UInt32 = 1
    static let move: UInt32 = 2
    static let cancel: UInt32 = 3

    static let mouse: UInt32 = 0
    static let touch: UInt32 = 1
    static let pen: UInt32 = 2
}

/// A `PointerEvent` on a window's canvas. `button` is the one that changed
/// (0 primary, 2 secondary), `buttons` the bitmask still held; a touch's or
/// pen's `pointerId` identifies it through its down → move → up sequence.
@_expose(wasm, "nucleant_pointer")
public func nucleantPointer(
    _ window: UInt32, _ phase: UInt32, _ x: Double, _ y: Double,
    _ button: UInt32, _ buttons: UInt32, _ pointerId: UInt32, _ pointerType: UInt32
) {
    guard let handler = BrowserWindow.window(window)?.handler else { return }
    let location = SIMD2(x, y)
    if pointerType == BrowserPointer.mouse {
        switch phase {
        case BrowserPointer.down:
            if button == 2 { handler.browserRightPointerDown(at: location) } else if button == 0 { handler.browserPointerDown(at: location) }
        case BrowserPointer.up:
            if button == 2 { handler.browserRightPointerUp(at: location) } else if button == 0 { handler.browserPointerUp(at: location) }
        case BrowserPointer.move:
            if buttons & 1 != 0 { handler.browserPointerDragged(at: location) } else { handler.browserPointerMoved(to: location) }
        default:
            handler.browserPointerUp(at: location)
        }
    } else {
        // Touch and pen arrive as touches, as an Apple Pencil does on iOS.
        let id = Int(pointerId)
        switch phase {
        case BrowserPointer.down: handler.browserTouchDown(id: id, at: location)
        case BrowserPointer.up: handler.browserTouchUp(id: id, at: location)
        case BrowserPointer.move: handler.browserTouchMoved(id: id, at: location)
        default: handler.browserTouchCancelled(id: id, at: location)
        }
    }
}

/// A wheel / trackpad scroll, already in points and in AppKit's sign
/// convention, which `on_scroll` is specified against: positive towards the
/// top/left of the content — the DOM's `deltaX`/`deltaY` negated.
@_expose(wasm, "nucleant_wheel")
public func nucleantWheel(_ window: UInt32, _ dx: Double, _ dy: Double) {
    BrowserWindow.window(window)?.handler?.browserScrolled(dx: dx, dy: dy)
}

/// A key going down (`down` 1, including repeats) or up. The key's `code` and
/// `key` strings are read through `nwd_event_string` while this runs.
@_expose(wasm, "nucleant_key")
public func nucleantKey(_ window: UInt32, _ down: UInt32) {
    guard let handler = BrowserWindow.window(window)?.handler else { return }
    let code = eventString(0)
    let characters = BrowserKeyMap.characters(forKey: eventString(1))
    // A key the table doesn't know still reports, as code 0xFFFF, so its
    // characters reach the window.
    let key = BrowserKeyMap.keyCode(forCode: code) ?? 0xFFFF
    if down != 0 {
        handler.browserKeyDown(key: key, chars: characters)
    } else {
        handler.browserKeyUp(key: key, chars: characters)
    }
}

/// String `which` of the event being delivered — staged by the page before
/// the export runs (`nwd_event_string`).
func eventString(_ which: UInt32) -> String {
    var buffer = [UInt8](repeating: 0, count: 64)
    var length = Int(buffer.withUnsafeMutableBytes {
        nwd_event_string(which, $0.baseAddress!.assumingMemoryBound(to: CChar.self), UInt32($0.count))
    })
    if length > buffer.count {
        buffer = [UInt8](repeating: 0, count: length)
        length = Int(buffer.withUnsafeMutableBytes {
            nwd_event_string(which, $0.baseAddress!.assumingMemoryBound(to: CChar.self), UInt32($0.count))
        })
    }
    return String(decoding: buffer.prefix(length), as: UTF8.self)
}
#endif
