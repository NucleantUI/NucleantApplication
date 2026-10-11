//
//  DispatchTime.swift
//  Dispatch (WebAssembly)
//
//  Points in time on the monotonic clock, as libdispatch's `DispatchTime`:
//  `DispatchTime.now().uptimeNanoseconds` for measuring, and
//  `.now() + seconds` for an `asyncAfter` deadline.
//
#if os(WASI)
import CDispatchWasm

public struct DispatchTime: Comparable, Hashable, Sendable {

    /// Nanoseconds on the monotonic clock.
    public let uptimeNanoseconds: UInt64

    public init(uptimeNanoseconds: UInt64) {
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public static func now() -> DispatchTime {
        DispatchTime(uptimeNanoseconds: ndw_monotonic_nanoseconds())
    }

    public static let distantFuture = DispatchTime(uptimeNanoseconds: .max)

    public func distance(to other: DispatchTime) -> DispatchTimeInterval {
        let delta = Int64(bitPattern: other.uptimeNanoseconds &- uptimeNanoseconds)
        return .nanoseconds(Int(clamping: delta))
    }

    public static func < (lhs: DispatchTime, rhs: DispatchTime) -> Bool {
        lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }
}

public enum DispatchTimeInterval: Equatable, Hashable, Sendable {
    case seconds(Int)
    case milliseconds(Int)
    case microseconds(Int)
    case nanoseconds(Int)
    case never

    /// Signed nanoseconds; `.never` as the largest.
    var nanoseconds: Int64 {
        switch self {
        case .seconds(let s):      return Int64(s).multipliedReportingOverflow(by: 1_000_000_000).partialValue
        case .milliseconds(let m): return Int64(m).multipliedReportingOverflow(by: 1_000_000).partialValue
        case .microseconds(let u): return Int64(u).multipliedReportingOverflow(by: 1_000).partialValue
        case .nanoseconds(let n):  return Int64(n)
        case .never:               return .max
        }
    }
}

public func + (time: DispatchTime, seconds: Double) -> DispatchTime {
    time.adding(nanoseconds: seconds * 1_000_000_000)
}

public func - (time: DispatchTime, seconds: Double) -> DispatchTime {
    time.adding(nanoseconds: -seconds * 1_000_000_000)
}

public func + (time: DispatchTime, interval: DispatchTimeInterval) -> DispatchTime {
    if interval == .never { return .distantFuture }
    return time.adding(nanoseconds: Double(interval.nanoseconds))
}

public func - (time: DispatchTime, interval: DispatchTimeInterval) -> DispatchTime {
    if interval == .never { return DispatchTime(uptimeNanoseconds: 0) }
    return time.adding(nanoseconds: -Double(interval.nanoseconds))
}

extension DispatchTime {
    /// Saturating at both ends, as libdispatch's arithmetic is.
    fileprivate func adding(nanoseconds delta: Double) -> DispatchTime {
        guard uptimeNanoseconds != .max else { return self }
        let result = Double(uptimeNanoseconds) + delta.rounded()
        if result <= 0 { return DispatchTime(uptimeNanoseconds: 0) }
        if result >= Double(UInt64.max) { return .distantFuture }
        return DispatchTime(uptimeNanoseconds: UInt64(result))
    }
}
#endif
