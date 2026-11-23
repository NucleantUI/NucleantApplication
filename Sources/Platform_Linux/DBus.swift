//
//  DBus.swift
//  NucleantApplication
//
//  The part of D-Bus this module speaks itself: a connection to the session
//  bus, messages in and out of it, and the values they carry. The system tray
//  (`StatusNotifierTray`) serves objects on it; the desktop's appearance
//  (`DesktopAppearance`) asks the portal one question over it.
//
//  The wire protocol rather than libdbus: libdbus would mean a
//  `.systemLibrary` needing `libdbus-1-dev` at build time on every machine
//  that compiles this, where the runtime `libdbus-1.so.3` is everywhere and
//  the headers are not — the trade `CXCB` makes too, linking core libxcb and
//  setting its atoms by hand rather than pulling in xcb-icccm and xcb-ewmh.
//  What that costs is bounded: no object model, no main-loop integration of
//  its own — the event loop asks for what has arrived (`receive()`) once a
//  turn — and only the session bus.
//
// https://dbus.freedesktop.org/doc/dbus-specification.html
//
#if os(Linux)
import Foundation
import Glibc

// MARK: - Values

/// A D-Bus value, as the wire protocol marshals it. Each one knows its own
/// type signature, which a variant carries and a message's body is described
/// by.
indirect enum DBusValue: Equatable {
    case byte(UInt8)
    case boolean(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    case unixFD(UInt32)
    case variant(DBusValue)
    /// `ay`, kept as bytes: an icon is tens of thousands of them.
    case bytes([UInt8])
    /// An array of `element`-typed values. The element's signature is the
    /// array's own, so an empty array still has one.
    case array(element: String, [DBusValue])
    case structure([DBusValue])
    case dictEntry(DBusValue, DBusValue)

    var signature: String {
        switch self {
        case .byte: "y"
        case .boolean: "b"
        case .int16: "n"
        case .uint16: "q"
        case .int32: "i"
        case .uint32: "u"
        case .int64: "x"
        case .uint64: "t"
        case .double: "d"
        case .string: "s"
        case .objectPath: "o"
        case .signature: "g"
        case .unixFD: "h"
        case .variant: "v"
        case .bytes: "ay"
        case .array(let element, _): "a" + element
        case .structure(let fields): "(" + fields.map(\.signature).joined() + ")"
        case .dictEntry(let key, let value): "{" + key.signature + value.signature + "}"
        }
    }

    /// `a{sv}`: the shape properties travel in.
    static func properties(_ pairs: [(String, DBusValue)]) -> DBusValue {
        .array(element: "{sv}", pairs.map { .dictEntry(.string($0.0), .variant($0.1)) })
    }

    // MARK: Reading one back

    /// What is inside, through any number of variants.
    var unwrapped: DBusValue {
        var value = self
        for _ in 0..<8 {
            guard case .variant(let inner) = value else { break }
            value = inner
        }
        return value
    }

    var int32: Int32? {
        if case .int32(let value) = unwrapped { value } else { nil }
    }

    var uint32: UInt32? {
        if case .uint32(let value) = unwrapped { value } else { nil }
    }

    /// A string, an object path or a signature.
    var string: String? {
        switch unwrapped {
        case .string(let value), .objectPath(let value), .signature(let value): value
        default: nil
        }
    }

    /// The elements of an array — of an `ay` too, as bytes.
    var elements: [DBusValue]? {
        switch unwrapped {
        case .array(_, let values): values
        case .bytes(let bytes): bytes.map(DBusValue.byte)
        default: nil
        }
    }

    var fields: [DBusValue]? {
        if case .structure(let fields) = unwrapped { fields } else { nil }
    }
}

// MARK: - Signatures

enum DBusSignature {
    /// The alignment a value of `type` starts at, which its first character
    /// says.
    static func alignment(of type: Substring) -> Int {
        switch type.first {
        case "n", "q": 2
        case "b", "i", "u", "s", "o", "a", "h": 4
        case "x", "t", "d", "(", "{": 8
        default: 1   // y, g, v
        }
    }

    /// The first complete type in `signature`, and what follows it; nil if
    /// it is not well formed.
    static func splitFirst(_ signature: Substring) -> (type: Substring, rest: Substring)? {
        guard let first = signature.first else { return nil }
        switch first {
        case "a":
            guard let (element, _) = splitFirst(signature.dropFirst()) else { return nil }
            let end = signature.index(signature.startIndex, offsetBy: 1 + element.count)
            return (signature[..<end], signature[end...])
        case "(", "{":
            let close: Character = first == "(" ? ")" : "}"
            var depth = 0
            for index in signature.indices {
                let character = signature[index]
                if character == "(" || character == "{" { depth += 1 }
                if character == ")" || character == "}" {
                    depth -= 1
                    if depth == 0 {
                        guard character == close else { return nil }
                        let end = signature.index(after: index)
                        return (signature[..<end], signature[end...])
                    }
                }
            }
            return nil
        default:
            let end = signature.index(after: signature.startIndex)
            return (signature[..<end], signature[end...])
        }
    }

    /// Each complete type in `signature`, in order.
    static func types(in signature: Substring) -> [Substring]? {
        var types: [Substring] = []
        var rest = signature
        while !rest.isEmpty {
            guard let (type, remainder) = splitFirst(rest) else { return nil }
            types.append(type)
            rest = remainder
        }
        return types
    }
}

// MARK: - Marshalling

/// Lays values out in the wire format, little-endian. Alignment is measured
/// from the start of `bytes`, so a body written on its own lines up once it
/// is put after a header — which ends 8-aligned.
struct DBusWriter {
    var bytes: [UInt8] = []

    mutating func pad(to alignment: Int) {
        while bytes.count % alignment != 0 { bytes.append(0) }
    }

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        pad(to: MemoryLayout<T>.size)
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func write(_ value: DBusValue) {
        switch value {
        case .byte(let value): bytes.append(value)
        case .boolean(let value): append(UInt32(value ? 1 : 0))
        case .int16(let value): append(value)
        case .uint16(let value): append(value)
        case .int32(let value): append(value)
        case .uint32(let value): append(value)
        case .int64(let value): append(value)
        case .uint64(let value): append(value)
        case .double(let value): append(value.bitPattern)
        case .unixFD(let value): append(value)
        case .string(let value), .objectPath(let value):
            let utf8 = Array(value.utf8)
            append(UInt32(utf8.count))
            bytes.append(contentsOf: utf8)
            bytes.append(0)
        case .signature(let value):
            writeSignature(value)
        case .variant(let inner):
            writeSignature(inner.signature)
            write(inner)
        case .bytes(let values):
            append(UInt32(values.count))
            bytes.append(contentsOf: values)
        case .array(let element, let values):
            // The length counts the elements only, not the padding before
            // the first one — so it is patched in once they are laid out.
            append(UInt32(0))
            let lengthAt = bytes.count - 4
            pad(to: DBusSignature.alignment(of: Substring(element)))
            let start = bytes.count
            for value in values { write(value) }
            let length = UInt32(bytes.count - start).littleEndian
            withUnsafeBytes(of: length) { raw in
                for (offset, byte) in raw.enumerated() { bytes[lengthAt + offset] = byte }
            }
        case .structure(let fields):
            pad(to: 8)
            for field in fields { write(field) }
        case .dictEntry(let key, let value):
            pad(to: 8)
            write(key)
            write(value)
        }
    }

    private mutating func writeSignature(_ signature: String) {
        let utf8 = Array(signature.utf8)
        bytes.append(UInt8(truncatingIfNeeded: utf8.count))
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }
}

/// Reads values back in the sender's byte order. Offsets are from the start
/// of the message, which is what alignment is measured from.
struct DBusReader {
    let bytes: [UInt8]
    var offset: Int
    let littleEndian: Bool

    /// Deeper than any real message nests; past it is malice or a bug.
    private static let maximumDepth = 32

    mutating func pad(to alignment: Int) -> Bool {
        let padded = (offset + alignment - 1) / alignment * alignment
        guard padded <= bytes.count else { return false }
        offset = padded
        return true
    }

    mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard pad(to: size), offset + size <= bytes.count else { return nil }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { raw in
            for index in 0..<size { raw[index] = bytes[offset + index] }
        }
        offset += size
        return littleEndian ? T(littleEndian: value) : T(bigEndian: value)
    }

    /// The values of `signature`, one per complete type in it.
    mutating func read(signature: String) -> [DBusValue]? {
        guard let types = DBusSignature.types(in: Substring(signature)) else { return nil }
        var values: [DBusValue] = []
        for type in types {
            guard let value = read(type: type, depth: 0) else { return nil }
            values.append(value)
        }
        return values
    }

    private mutating func read(type: Substring, depth: Int) -> DBusValue? {
        guard depth < Self.maximumDepth, let first = type.first else { return nil }
        switch first {
        case "y":
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return .byte(bytes[offset])
        case "b": return integer(UInt32.self).map { .boolean($0 != 0) }
        case "n": return integer(Int16.self).map(DBusValue.int16)
        case "q": return integer(UInt16.self).map(DBusValue.uint16)
        case "i": return integer(Int32.self).map(DBusValue.int32)
        case "u": return integer(UInt32.self).map(DBusValue.uint32)
        case "x": return integer(Int64.self).map(DBusValue.int64)
        case "t": return integer(UInt64.self).map(DBusValue.uint64)
        case "d": return integer(UInt64.self).map { .double(Double(bitPattern: $0)) }
        case "h": return integer(UInt32.self).map(DBusValue.unixFD)
        case "s": return readString().map(DBusValue.string)
        case "o": return readString().map(DBusValue.objectPath)
        case "g": return readSignature().map(DBusValue.signature)
        case "v":
            guard let inner = readSignature(),
                  let (innerType, rest) = DBusSignature.splitFirst(Substring(inner)), rest.isEmpty,
                  let value = read(type: innerType, depth: depth + 1)
            else { return nil }
            return .variant(value)
        case "a":
            let element = type.dropFirst()
            guard let length = integer(UInt32.self), length <= 64 << 20,
                  pad(to: DBusSignature.alignment(of: element))
            else { return nil }
            let end = offset + Int(length)
            guard end <= bytes.count else { return nil }
            if element == "y" {
                defer { offset = end }
                return .bytes(Array(bytes[offset..<end]))
            }
            var values: [DBusValue] = []
            while offset < end {
                guard let value = read(type: element, depth: depth + 1) else { return nil }
                values.append(value)
            }
            return offset == end ? .array(element: String(element), values) : nil
        case "(":
            guard pad(to: 8), let fields = DBusSignature.types(in: type.dropFirst().dropLast()) else { return nil }
            var values: [DBusValue] = []
            for field in fields {
                guard let value = read(type: field, depth: depth + 1) else { return nil }
                values.append(value)
            }
            return .structure(values)
        case "{":
            guard pad(to: 8), let pair = DBusSignature.types(in: type.dropFirst().dropLast()), pair.count == 2,
                  let key = read(type: pair[0], depth: depth + 1),
                  let value = read(type: pair[1], depth: depth + 1)
            else { return nil }
            return .dictEntry(key, value)
        default:
            return nil
        }
    }

    private mutating func readString() -> String? {
        guard let length = integer(UInt32.self), offset + Int(length) + 1 <= bytes.count else { return nil }
        defer { offset += Int(length) + 1 }
        return String(decoding: bytes[offset..<offset + Int(length)], as: UTF8.self)
    }

    private mutating func readSignature() -> String? {
        guard offset < bytes.count else { return nil }
        let length = Int(bytes[offset])
        guard offset + 1 + length + 1 <= bytes.count else { return nil }
        defer { offset += 1 + length + 1 }
        return String(decoding: bytes[offset + 1..<offset + 1 + length], as: UTF8.self)
    }
}

// MARK: - Messages

/// One message: a method call, its return or error, or a signal.
struct DBusMessage {
    enum Kind: UInt8 {
        case methodCall = 1
        case methodReturn = 2
        case error = 3
        case signal = 4
    }

    /// The caller wants no reply; one would only be dropped.
    static let noReplyExpected: UInt8 = 0x1

    var kind: Kind
    var flags: UInt8 = 0
    var serial: UInt32 = 0
    var path: String?
    var interface: String?
    var member: String?
    var errorName: String?
    var replySerial: UInt32?
    var destination: String?
    var sender: String?
    var body: [DBusValue] = []

    var bodySignature: String { body.map(\.signature).joined() }

    var expectsReply: Bool { kind == .methodCall && flags & Self.noReplyExpected == 0 }

    static func methodCall(
        destination: String?, path: String, interface: String?, member: String, body: [DBusValue] = []
    ) -> DBusMessage {
        DBusMessage(kind: .methodCall, path: path, interface: interface, member: member,
                    destination: destination, body: body)
    }

    static func signal(path: String, interface: String, member: String, body: [DBusValue] = []) -> DBusMessage {
        DBusMessage(kind: .signal, path: path, interface: interface, member: member, body: body)
    }

    /// The return for `call`, carrying `body`.
    static func reply(to call: DBusMessage, body: [DBusValue] = []) -> DBusMessage {
        DBusMessage(kind: .methodReturn, replySerial: call.serial, destination: call.sender, body: body)
    }

    /// An error for `call`: `name` is its D-Bus error name, `text` says what
    /// happened.
    static func error(to call: DBusMessage, name: String, text: String) -> DBusMessage {
        DBusMessage(kind: .error, errorName: name, replySerial: call.serial,
                    destination: call.sender, body: [.string(text)])
    }

    /// The message on the wire, numbered `serial`.
    func encoded(serial: UInt32) -> [UInt8] {
        var body = DBusWriter()
        for value in self.body { body.write(value) }

        var fields: [DBusValue] = []
        func field(_ code: UInt8, _ value: DBusValue?) {
            if let value { fields.append(.structure([.byte(code), .variant(value)])) }
        }
        field(1, path.map(DBusValue.objectPath))
        field(2, interface.map(DBusValue.string))
        field(3, member.map(DBusValue.string))
        field(4, errorName.map(DBusValue.string))
        field(5, replySerial.map(DBusValue.uint32))
        field(6, destination.map(DBusValue.string))
        field(8, self.body.isEmpty ? nil : .signature(bodySignature))

        var message = DBusWriter()
        message.bytes.append(UInt8(ascii: "l"))
        message.bytes.append(kind.rawValue)
        message.bytes.append(flags)
        message.bytes.append(1)                       // protocol version
        message.append(UInt32(body.bytes.count))
        message.append(serial)
        message.write(.array(element: "(yv)", fields))
        message.pad(to: 8)                            // the body starts 8-aligned
        message.bytes.append(contentsOf: body.bytes)
        return message.bytes
    }

    /// The first message in `buffer` and how many bytes it took; nil while
    /// it has not all arrived. `malformed` is set when it never will parse —
    /// the connection is beyond saving then.
    static func decode(_ buffer: [UInt8], malformed: inout Bool) -> (message: DBusMessage, length: Int)? {
        guard buffer.count >= 16 else { return nil }
        let littleEndian: Bool
        switch buffer[0] {
        case UInt8(ascii: "l"): littleEndian = true
        case UInt8(ascii: "B"): littleEndian = false
        default:
            malformed = true
            return nil
        }
        var header = DBusReader(bytes: buffer, offset: 4, littleEndian: littleEndian)
        guard let bodyLength = header.integer(UInt32.self),
              let serial = header.integer(UInt32.self),
              let fieldsLength = header.integer(UInt32.self)
        else { return nil }
        let bodyStart = (16 + Int(fieldsLength) + 7) / 8 * 8
        let total = bodyStart + Int(bodyLength)
        guard fieldsLength < 64 << 20, bodyLength < 128 << 20 else {
            malformed = true
            return nil
        }
        guard buffer.count >= total else { return nil }

        let bytes = Array(buffer[0..<total])
        guard let kind = Kind(rawValue: bytes[1]) else {
            // An unknown kind must be ignored, not fail the connection.
            return (DBusMessage(kind: .signal, serial: serial), total)
        }
        var message = DBusMessage(kind: kind, flags: bytes[2], serial: serial)
        var reader = DBusReader(bytes: bytes, offset: 12, littleEndian: littleEndian)
        guard let fields = reader.read(signature: "a(yv)")?.first?.elements else {
            malformed = true
            return nil
        }
        var signature = ""
        for field in fields {
            guard let parts = field.fields, parts.count == 2, case .byte(let code) = parts[0] else { continue }
            let value = parts[1]
            switch code {
            case 1: message.path = value.string
            case 2: message.interface = value.string
            case 3: message.member = value.string
            case 4: message.errorName = value.string
            case 5: message.replySerial = value.uint32
            case 6: message.destination = value.string
            case 7: message.sender = value.string
            case 8: signature = value.string ?? ""
            default: break
            }
        }
        if !signature.isEmpty {
            var body = DBusReader(bytes: bytes, offset: bodyStart, littleEndian: littleEndian)
            guard let values = body.read(signature: signature) else {
                malformed = true
                return nil
            }
            message.body = values
        }
        return (message, total)
    }
}

// MARK: - The connection

/// A connection to the session bus. Not thread-safe: made, used and closed
/// on the thread that runs the event loop.
///
/// The socket is non-blocking. Setting up — connecting, authenticating,
/// `Hello` — and `call(…)` wait, each for at most its timeout; everything
/// else is sent at once and read back by `receive()`, which never waits.
final class DBusConnection {

    private var fd: Int32
    /// What the bus calls this connection, from `Hello`.
    private(set) var uniqueName = ""
    private var inbound: [UInt8] = []
    /// Messages read while `call` waited for its reply, for `receive()`.
    private var held: [DBusMessage] = []
    private var nextSerial: UInt32 = 1

    var isOpen: Bool { fd >= 0 }

    /// The session bus, or nil if there is none to reach — no
    /// `DBUS_SESSION_BUS_ADDRESS`, nothing listening, or a bus that won't
    /// let this process in.
    static func session(timeout: Double = 1) -> DBusConnection? {
        guard let address = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"],
              let connection = DBusConnection(address: address, timeout: timeout)
        else { return nil }
        guard let hello = connection.call(
            .methodCall(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                        interface: "org.freedesktop.DBus", member: "Hello"),
            timeout: timeout
        ), hello.kind == .methodReturn, let name = hello.body.first?.string else {
            connection.close()
            return nil
        }
        connection.uniqueName = name
        return connection
    }

    private init?(address: String, timeout: Double) {
        // `unix:path=…` is what a session bus is in practice;
        // `unix:abstract=…` appears on older systems, in the Linux-only
        // abstract namespace, which is a leading NUL in the socket path.
        var path: String?
        var abstract = false
        for transport in address.split(separator: ";") {
            guard transport.hasPrefix("unix:") else { continue }
            for field in transport.dropFirst("unix:".count).split(separator: ",") {
                if field.hasPrefix("path=") {
                    path = Self.unescape(field.dropFirst("path=".count))
                } else if field.hasPrefix("abstract=") {
                    path = Self.unescape(field.dropFirst("abstract=".count))
                    abstract = true
                }
            }
            if path != nil { break }
        }
        guard let socketPath = path else { return nil }

        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.utf8)
        // One byte for the leading NUL of an abstract name, one for the
        // terminator of a filesystem one — either way the name must fit.
        guard utf8.count + 1 <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close()
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let start = abstract ? 1 : 0
            for (index, byte) in utf8.enumerated() { raw[start + index] = byte }
        }
        let length = abstract
            ? socklen_t(MemoryLayout<sa_family_t>.size + 1 + utf8.count)
            : socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(fd, $0, length) }
        }
        guard connected == 0 else {
            close()
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        guard authenticate(timeout: timeout) else {
            close()
            return nil
        }
    }

    deinit {
        close()
    }

    func close() {
        guard fd >= 0 else { return }
        Glibc.close(fd)
        fd = -1
    }

    /// `%xx` escapes in an address value.
    private static func unescape(_ value: Substring) -> String {
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "%", let end = value.index(index, offsetBy: 3, limitedBy: value.endIndex),
               let byte = UInt8(value[value.index(after: index)..<end], radix: 16) {
                bytes.append(byte)
                index = end
            } else {
                bytes.append(contentsOf: Array(String(value[index]).utf8))
                index = value.index(after: index)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Auth

    /// SASL EXTERNAL: the kernel already told the bus who is on the other
    /// end of the socket, so the "credential" is just this process's uid, in
    /// hex. A NUL byte is required before any of it.
    private func authenticate(timeout: Double) -> Bool {
        let uid = String(getuid()).utf8.map { String(format: "%02x", $0) }.joined()
        guard write([0] + Array("AUTH EXTERNAL \(uid)\r\n".utf8), timeout: timeout),
              let reply = readLine(timeout: timeout), reply.hasPrefix("OK")
        else { return false }
        return write(Array("BEGIN\r\n".utf8), timeout: timeout)
    }

    private func readLine(timeout: Double) -> String? {
        let deadline = Self.now() + timeout
        while true {
            if let newline = inbound.firstIndex(of: 0x0a) {
                var line = Array(inbound[..<newline])
                inbound.removeSubrange(...newline)
                if line.last == 0x0d { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            guard inbound.count < 4096, waitReadable(until: deadline), readAvailable() else { return nil }
        }
    }

    // MARK: Sending

    /// Sends `message` and returns the serial it went with — what its reply
    /// will name. Nil if the connection is gone.
    @discardableResult
    func send(_ message: DBusMessage) -> UInt32? {
        guard isOpen else { return nil }
        let serial = nextSerial
        nextSerial = nextSerial == UInt32.max ? 1 : nextSerial + 1
        guard write(message.encoded(serial: serial), timeout: 1) else {
            close()
            return nil
        }
        return serial
    }

    /// Answers `call` with `body`, unless it asked for no answer.
    func reply(to call: DBusMessage, _ body: [DBusValue] = []) {
        guard call.expectsReply else { return }
        send(.reply(to: call, body: body))
    }

    func replyError(to call: DBusMessage, name: String, text: String) {
        guard call.expectsReply else { return }
        send(.error(to: call, name: name, text: text))
    }

    /// Sends `message` and waits up to `timeout` seconds for its reply — a
    /// return or an error. Whatever else arrives meanwhile waits for
    /// `receive()`.
    func call(_ message: DBusMessage, timeout: Double) -> DBusMessage? {
        guard let serial = send(message) else { return nil }
        let deadline = Self.now() + timeout
        while true {
            guard let messages = parse() else { return nil }
            var reply: DBusMessage?
            for message in messages {
                if reply == nil, message.kind == .methodReturn || message.kind == .error, message.replySerial == serial {
                    reply = message
                } else {
                    held.append(message)
                }
            }
            if let reply { return reply }
            guard waitReadable(until: deadline), readAvailable() else { return nil }
        }
    }

    // MARK: Receiving

    /// Every message that has arrived, without waiting. Nil once the
    /// connection is gone — the bus closed it, or it broke.
    func receive() -> [DBusMessage]? {
        guard isOpen else { return nil }
        guard readAvailable(), let parsed = parse() else {
            close()
            return nil
        }
        let messages = held + parsed
        held = []
        return messages
    }

    /// The complete messages in the buffer, taken out of it. Nil if what is
    /// there can never be a message.
    private func parse() -> [DBusMessage]? {
        var messages: [DBusMessage] = []
        var malformed = false
        while let (message, length) = DBusMessage.decode(inbound, malformed: &malformed) {
            inbound.removeSubrange(0..<length)
            messages.append(message)
        }
        if malformed {
            close()
            return nil
        }
        return messages
    }

    // MARK: Socket

    /// Reads whatever the socket has. False if it is closed or broken.
    private func readAvailable() -> Bool {
        guard isOpen else { return false }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                inbound.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 { return false }   // the bus hung up
            return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
        }
    }

    private func write(_ bytes: [UInt8], timeout: Double) -> Bool {
        let deadline = Self.now() + timeout
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes {
                Glibc.write(fd, $0.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if count > 0 {
                sent += count
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                guard wait(for: Int16(POLLOUT), until: deadline) else { return false }
            } else {
                return false
            }
        }
        return true
    }

    private func waitReadable(until deadline: Double) -> Bool {
        wait(for: Int16(POLLIN), until: deadline)
    }

    private func wait(for events: Int16, until deadline: Double) -> Bool {
        let remaining = deadline - Self.now()
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
        return ready > 0 && descriptor.revents & events != 0
    }

    private static func now() -> Double {
        waylandMonotonicSeconds()
    }
}

/// The names of the errors D-Bus itself defines, for replies.
enum DBusError {
    static let unknownMethod = "org.freedesktop.DBus.Error.UnknownMethod"
    static let unknownObject = "org.freedesktop.DBus.Error.UnknownObject"
    static let unknownInterface = "org.freedesktop.DBus.Error.UnknownInterface"
    static let unknownProperty = "org.freedesktop.DBus.Error.UnknownProperty"
    static let invalidArgs = "org.freedesktop.DBus.Error.InvalidArgs"
    static let propertyReadOnly = "org.freedesktop.DBus.Error.PropertyReadOnly"
}
#endif
