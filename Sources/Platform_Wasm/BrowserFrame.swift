//
//  BrowserFrame.swift
//  NucleantApplication
//
//  A web page shown over a window: an <iframe> the page lays over the
//  window's canvas. The browser's counterpart of hosting a web view inside a
//  native window — the page the app runs in is a browser already, so a page
//  inside the app is a frame of it, drawn and driven by the browser itself.
//
#if os(WASI)
import CWasmDOM

/// An `<iframe>` over a window's canvas.
///
/// Positioned in the window's CSS pixels — the space every coordinate the
/// window reports is in — and cut to the part that shows, so a frame inside
/// a scrolled or clipped view is cut where the view is. It sits over the
/// canvas: whatever the window draws under it is hidden by it. The browser
/// draws the page and gives it the pointer and the keys directly.
///
/// A page from the app's own origin can be scripted (`evaluate`), and is
/// given a query function under the name passed to `init` — the shape of
/// CEF's `window.cefQuery`, so a page written for CEF talks to the app
/// unchanged:
///
/// ```js
/// window.cefQuery({ request, persistent: false, onSuccess(response) {}, onFailure(code, message) {} });
/// ```
///
/// Each call arrives in `onQuery` and is answered with `succeed` or `fail` —
/// once, or for a persistent query as often as there is something to send,
/// until it fails or the page cancels it (`onQueryCanceled`). A page from
/// another origin gets neither: the browser keeps its document out of reach.
///
/// Every callback is made on the page's one thread, from an export the page
/// calls.
public final class BrowserFrame {

    /// The id the page knows the frame by.
    public let id: UInt32

    /// A document finished loading: its address and title. A page from
    /// another origin reports the address it was sent to and no title.
    public var onLoad: ((_ url: String, _ title: String) -> Void)?

    /// The page called its query function. `frameURL` is the address of the
    /// document that asked — check it before trusting the request.
    public var onQuery: ((_ query: UInt32, _ request: String, _ frameURL: String, _ isPersistent: Bool) -> Void)?

    /// A query not yet finished has gone: the page canceled it or left the
    /// document that made it. Answers to it are ignored.
    public var onQueryCanceled: ((_ query: UInt32) -> Void)?

    /// The page wrote to its console, or threw: `level` is 1 for debug, 2
    /// log and info, 3 warnings, 4 errors.
    public var onConsoleMessage: ((_ level: Int, _ message: String, _ source: String, _ line: Int) -> Void)?

    /// Kept off the screen, wherever it is placed.
    public var isHidden = true {
        didSet {
            guard isHidden != oldValue, !destroyed else { return }
            nwd_frame_set_hidden(id, isHidden ? 1 : 0)
        }
    }

    /// The page's zoom, 1 being 100%; it carries over to every page loaded.
    public var zoom: Double = 1 {
        didSet {
            guard zoom != oldValue, !destroyed else { return }
            nwd_frame_set_zoom(id, zoom)
        }
    }

    private(set) var destroyed = false

    /// Every live frame by id — how an export finds its frame. Weak: the
    /// frame belongs to whoever made it.
    private nonisolated(unsafe) static var live: [UInt32: Weak] = [:]

    private struct Weak {
        weak var frame: BrowserFrame?
    }

    static func frame(_ id: UInt32) -> BrowserFrame? {
        live[id]?.frame
    }

    /// - Parameters:
    ///   - background: shown where the page draws nothing, ARGB — and while
    ///     it loads. 0 is clear.
    ///   - queryFunction: the name the page's query function goes under —
    ///     `"cefQuery"` for a page written for CEF; empty for none.
    public init(background: UInt32 = 0, queryFunction: String = "") {
        var name = queryFunction
        id = name.withUTF8 { nwd_frame_create(background, $0.baseAddress, UInt32($0.count)) }
        Self.live[id] = Weak(frame: self)
    }

    deinit {
        destroy()
    }

    /// Takes the frame off the page. Nothing it does is reported from here.
    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        Self.live[id] = nil
        nwd_frame_destroy(id)
    }

    // MARK: - Place

    /// Over window `window` (`PlatformWindow.windowID`): `frame` is where
    /// the page goes and `visible` the part of it that shows, both
    /// (x, y, width, height) in the window's CSS pixels.
    public func place(inWindow window: UInt32, frame: SIMD4<Double>, visible: SIMD4<Double>) {
        guard !destroyed else { return }
        var geometry = [frame.x, frame.y, frame.z, frame.w, visible.x, visible.y, visible.z, visible.w]
        geometry.withUnsafeMutableBufferPointer { nwd_frame_set_geometry(id, window, $0.baseAddress) }
    }

    // MARK: - The page

    /// Navigates to `url`, absolute or relative to the app's page.
    public func load(_ url: String) {
        guard !destroyed else { return }
        var url = url
        url.withUTF8 { nwd_frame_load(id, $0.baseAddress, UInt32($0.count)) }
    }

    /// Runs `script` in the page — after the current call into the module
    /// has returned, in the order given. Only a page from the app's own
    /// origin can be scripted; for any other this logs and does nothing.
    public func evaluate(_ script: String) {
        guard !destroyed else { return }
        var script = script
        script.withUTF8 { nwd_frame_evaluate(id, $0.baseAddress, UInt32($0.count)) }
    }

    public enum Navigation: UInt32, Sendable {
        case back = 0
        case forward = 1
        case reload = 2
        case reloadIgnoringCache = 3
        case stop = 4
    }

    /// Back and forward go through the page's own history, and so work only
    /// for a page from the app's origin; reloading works for any.
    public func navigate(_ navigation: Navigation) {
        guard !destroyed else { return }
        nwd_frame_navigate(id, navigation.rawValue)
    }

    // MARK: - Queries

    /// The query's onSuccess gets `response`. Finishes a query that isn't
    /// persistent.
    public func succeed(query: UInt32, response: String) {
        answer(query, success: true, code: 0, text: response)
    }

    /// The query's onFailure gets `code` and `message`. Finishes the query.
    public func fail(query: UInt32, code: Int, message: String) {
        answer(query, success: false, code: code, text: message)
    }

    private func answer(_ query: UInt32, success: Bool, code: Int, text: String) {
        guard !destroyed else { return }
        var text = text
        text.withUTF8 {
            nwd_frame_query_answer(id, query, success ? 1 : 0, Int32(clamping: code), $0.baseAddress, UInt32($0.count))
        }
    }
}

/// Where the page serves its mounted resources from.
public enum BrowserResources {

    /// The absolute URL the page serves the mounted resource file at `path`
    /// from — a file of a resource bundle, at the path `Bundle.module` gives
    /// it — or nil when `path` is not under the mounted resources.
    /// For a page in a `BrowserFrame` that ships in a bundle: the module
    /// reads the files, and the browser fetches the very same ones.
    public static func servedURL(forFile path: String) -> String? {
        var path = path
        var buffer = [UInt8](repeating: 0, count: 256)
        var length = 0
        for _ in 0..<2 {
            length = Int(path.withUTF8 { path in
                buffer.withUnsafeMutableBytes {
                    nwd_resource_url(path.baseAddress, UInt32(path.count),
                                     $0.baseAddress!.assumingMemoryBound(to: CChar.self), UInt32($0.count))
                }
            })
            guard length > buffer.count else { break }
            buffer = [UInt8](repeating: 0, count: length)
        }
        return length == 0 ? nil : String(decoding: buffer.prefix(length), as: UTF8.self)
    }
}

// MARK: - From the page

/// A document finished loading in `frame`: string 0 is its address, 1 its
/// title.
@_expose(wasm, "nucleant_browser_frame_loaded")
public func nucleantBrowserFrameLoaded(_ frame: UInt32) {
    guard let frame = BrowserFrame.frame(frame) else { return }
    frame.onLoad?(eventString(0), eventString(1))
}

/// The page in `frame` called its query function: string 0 is the request,
/// 1 the address of the document that asked.
@_expose(wasm, "nucleant_browser_frame_query")
public func nucleantBrowserFrameQuery(_ frame: UInt32, _ query: UInt32, _ persistent: UInt32) {
    guard let frame = BrowserFrame.frame(frame) else { return }
    guard let onQuery = frame.onQuery else {
        // Nobody listens: fail it as CEF's router fails an unhandled query.
        frame.fail(query: query, code: -1, message: "The query has been canceled")
        return
    }
    onQuery(query, eventString(0), eventString(1), persistent != 0)
}

@_expose(wasm, "nucleant_browser_frame_query_canceled")
public func nucleantBrowserFrameQueryCanceled(_ frame: UInt32, _ query: UInt32) {
    BrowserFrame.frame(frame)?.onQueryCanceled?(query)
}

/// The page in `frame` wrote to its console: string 0 is the message, 1 the
/// script it came from.
@_expose(wasm, "nucleant_browser_frame_console")
public func nucleantBrowserFrameConsole(_ frame: UInt32, _ level: UInt32, _ line: UInt32) {
    guard let frame = BrowserFrame.frame(frame), let onConsoleMessage = frame.onConsoleMessage else { return }
    onConsoleMessage(Int(level), eventString(0), eventString(1), Int(line))
}
#endif
