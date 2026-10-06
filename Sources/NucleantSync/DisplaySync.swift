/// Display-synced callbacks, one API on every platform.
///
/// Callbacks are grouped by frame rate: every callback asking for the same
/// `fps` shares one platform display-sync source (`SyncCallbackHandler`), so
/// ten 60 fps callbacks cost one display link, not ten. An `fps` of
/// `DisplaySync.maxFPS` asks for the display's own refresh rate.
///
/// Callbacks run on the main actor and receive the time in seconds since the
/// previous tick of their group.
@MainActor
public final class DisplaySync {

    /// Ask for the display's maximum refresh rate rather than a fixed one.
    public static let maxFPS = 0

    public static let shared = DisplaySync()

    /// One handler per requested fps. Only here to keep them alive.
    private var handlers: [Int: SyncCallbackHandler] = [:]

    private init() {}

    /// Registers `callback` to run at `fps` and returns the index to pass to
    /// `destroyCallback(fps:index:)`. Starts the group's sync source if this
    /// is its first callback.
    public static func newCallback(fps: Int, callback: @escaping @MainActor (Double) -> Void) -> Int {
        shared.newCallback(fps: fps, callback: callback)
    }

    /// Unregisters a callback. Stops and drops the group's sync source when
    /// its last callback goes. An unknown `fps`/`index` is ignored.
    public static func destroyCallback(fps: Int, index: Int) {
        shared.destroyCallback(fps: fps, index: index)
    }

    private func newCallback(fps: Int, callback: @escaping @MainActor (Double) -> Void) -> Int {
        let key = max(fps, Self.maxFPS)
        let handler = handlers[key] ?? {
            let new = SyncCallbackHandler(fps: key)
            handlers[key] = new
            return new
        }()
        return handler.add(callback)
    }

    private func destroyCallback(fps: Int, index: Int) {
        let key = max(fps, Self.maxFPS)
        guard let handler = handlers[key] else { return }
        handler.remove(index)
        if handler.isEmpty {
            handler.stop()
            handlers[key] = nil
        }
    }
}
