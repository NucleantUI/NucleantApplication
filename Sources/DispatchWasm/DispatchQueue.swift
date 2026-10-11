//
//  DispatchQueue.swift
//  Dispatch (WebAssembly)
//
//  libdispatch's queues on a platform with one thread. A wasm32-wasip1
//  module runs on the page's main thread and nowhere else, so every queue —
//  main, global, or one made with a label — is that thread's: work submitted
//  to any of them runs in order on the browser's main queue (MainQueue.swift)
//  once the call into the module that submitted it has returned, and `sync`
//  runs in place.
//
#if os(WASI)

public struct DispatchQoS: Equatable, Sendable {
    public enum QoSClass: Sendable {
        case background, utility, `default`, userInitiated, userInteractive, unspecified
    }

    public let qosClass: QoSClass

    public init(qosClass: QoSClass, relativePriority: Int) {
        self.qosClass = qosClass
    }

    public static let background = DispatchQoS(qosClass: .background, relativePriority: 0)
    public static let utility = DispatchQoS(qosClass: .utility, relativePriority: 0)
    public static let `default` = DispatchQoS(qosClass: .default, relativePriority: 0)
    public static let userInitiated = DispatchQoS(qosClass: .userInitiated, relativePriority: 0)
    public static let userInteractive = DispatchQoS(qosClass: .userInteractive, relativePriority: 0)
    public static let unspecified = DispatchQoS(qosClass: .unspecified, relativePriority: 0)
}

public final class DispatchQueue: @unchecked Sendable {

    public struct Attributes: OptionSet, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let concurrent = Attributes(rawValue: 1 << 1)
        public static let initiallyInactive = Attributes(rawValue: 1 << 2)
    }

    public let label: String

    public init(label: String, qos: DispatchQoS = .unspecified, attributes: Attributes = []) {
        self.label = label
    }

    /// The page's main thread — the only one there is.
    public static let main = DispatchQueue(label: "com.apple.main-thread")

    private static let globalQueue = DispatchQueue(label: "com.apple.root.default-qos")

    /// Runs on the main thread as well: there is no other to run it on.
    public static func global(qos: DispatchQoS.QoSClass = .default) -> DispatchQueue {
        globalQueue
    }

    /// `work` on the main queue's next turn, after what is already queued.
    public func async(execute work: @escaping @Sendable () -> Void) {
        MainQueue.enqueue(work)
    }

    /// `work` once `deadline` has passed, on the first main queue turn after
    /// it — in deadline order with other delayed work, in submission order
    /// for equal deadlines.
    public func asyncAfter(deadline: DispatchTime, execute work: @escaping @Sendable () -> Void) {
        MainQueue.enqueue(at: deadline.uptimeNanoseconds, work)
    }

    /// `work`, here and now. A queue would block this thread until its turn
    /// came, and on the one thread there is nothing else to wait for.
    public func sync<T>(execute work: () throws -> T) rethrows -> T {
        try work()
    }

    /// The iterations one after the other, on this thread.
    public static func concurrentPerform(iterations: Int, execute work: (Int) -> Void) {
        for index in 0..<iterations {
            work(index)
        }
    }
}
#endif
