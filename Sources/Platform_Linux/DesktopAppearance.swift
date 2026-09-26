//
//  DesktopAppearance.swift
//  NucleantApplication
//
#if os(Linux)
import Foundation
import Glibc

/// What the desktop asks applications to render as.
///
/// The values are `org.freedesktop.appearance color-scheme`'s own, so the
/// portal's reply maps straight onto this.
public enum DesktopColorScheme: UInt32, Sendable {
    case noPreference = 0
    case dark = 1
    case light = 2
}

/// The desktop's light/dark preference, read from the XDG desktop portal.
///
/// There is no X11 or Wayland protocol for this — it is a desktop setting, not
/// a display-server one — so the cross-desktop answer is the portal's
/// `org.freedesktop.appearance color-scheme`, which is what GTK, Qt, Firefox
/// and Chrome all read. Every desktop that has the setting exposes it there:
/// GNOME through xdg-desktop-portal-gnome, KDE through -kde, and Cinnamon,
/// MATE and Xfce through -xapp.
///
/// Deliberately *not* gsettings: `org.gnome.desktop.interface color-scheme`
/// exists on a Cinnamon session but nothing maintains it, so it reads
/// `'default'` on a Mint desktop that is plainly dark. The portal answers
/// correctly on the same machine.
///
/// ## Why this speaks the wire protocol
///
/// libdbus would mean a `.systemLibrary` needing `libdbus-1-dev` at build time
/// on every machine that compiles this, for one setting read once at startup —
/// the runtime `libdbus-1.so.3` is everywhere, the headers are not. The same
/// trade the neighbouring code already makes: `CXCB` links core libxcb and sets
/// its atoms by hand rather than pull in xcb-icccm and xcb-ewmh.
///
/// What that costs is bounded, because only a sliver of D-Bus is needed: one
/// blocking method call on the session bus, no signals, no object model, no
/// main-loop integration. Anything unexpected — no bus, no portal, a desktop
/// without the setting — is `.noPreference`, never a failure.
public enum DesktopAppearance {

    /// Ask the portal. Returns `.noPreference` if there is nobody to ask.
    ///
    /// Blocking, with a short timeout: called once while the first window is
    /// being built, where the alternative is drawing the wrong scheme and
    /// correcting it a frame later.
    public static func colorScheme() -> DesktopColorScheme {
        guard let bus = SessionBus() else { return .noPreference }
        defer { bus.close() }

        // `ReadOne` returns the value; the older `Read` wraps it in a second
        // variant. Portals still in the field implement one or the other, so
        // try the current name and fall back on any error.
        for method in ["ReadOne", "Read"] {
            guard let value = bus.call(
                destination: "org.freedesktop.portal.Desktop",
                path: "/org/freedesktop/portal/desktop",
                interface: "org.freedesktop.portal.Settings",
                member: method,
                arguments: ["org.freedesktop.appearance", "color-scheme"]
            ) else { continue }
            if let scheme = DesktopColorScheme(rawValue: value) { return scheme }
            // A value outside the enum is a desktop inventing its own; treat
            // it as "no preference" rather than guessing which way it meant.
            return .noPreference
        }
        return .noPreference
    }
}

// MARK: - Marshalling

/// D-Bus's alignment rule: every type starts at a multiple of its own size,
/// measured from the start of the message. Both halves below track that
/// against a base offset rather than their own buffer, because the header and
/// the body are laid out in one stream.
private struct Writer {
    var bytes: [UInt8] = []

    mutating func pad(to alignment: Int) {
        while bytes.count % alignment != 0 { bytes.append(0) }
    }

    mutating func byte(_ value: UInt8) { bytes.append(value) }

    mutating func uint32(_ value: UInt32) {
        pad(to: 4)
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    /// `s` and `o`: a length, the text, and a terminator that is not counted.
    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        uint32(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }

    /// `g`: the same shape with a single-byte length, and so no alignment.
    mutating func signature(_ value: String) {
        let utf8 = Array(value.utf8)
        bytes.append(UInt8(utf8.count))
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }
}

private struct Reader {
    let bytes: [UInt8]
    var offset = 0
    /// The bus replies in its own byte order and says so in the first byte.
    let littleEndian: Bool

    init(_ bytes: [UInt8], littleEndian: Bool) {
        self.bytes = bytes
        self.littleEndian = littleEndian
    }

    mutating func pad(to alignment: Int) {
        while offset % alignment != 0 { offset += 1 }
    }

    mutating func byte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint32() -> UInt32? {
        pad(to: 4)
        guard offset + 4 <= bytes.count else { return nil }
        defer { offset += 4 }
        let raw = bytes[offset..<offset + 4].reduce(into: [UInt8]()) { $0.append($1) }
        let value = raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return littleEndian ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }

    mutating func string() -> String? {
        guard let length = uint32(), offset + Int(length) + 1 <= bytes.count else { return nil }
        defer { offset += Int(length) + 1 }
        return String(decoding: bytes[offset..<offset + Int(length)], as: UTF8.self)
    }

    mutating func signature() -> String? {
        guard let length = byte(), offset + Int(length) + 1 <= bytes.count else { return nil }
        defer { offset += Int(length) + 1 }
        return String(decoding: bytes[offset..<offset + Int(length)], as: UTF8.self)
    }

    /// Unwrap variants down to the `u` this is after. `Read` nests two of
    /// them, which is why this recurses instead of unwrapping once.
    mutating func variantUInt32(depth: Int = 0) -> UInt32? {
        guard depth < 8, let inner = signature() else { return nil }
        switch inner {
        case "u": return uint32()
        case "v": return variantUInt32(depth: depth + 1)
        default: return nil
        }
    }
}

// MARK: - The bus

private final class SessionBus {

    private let fd: Int32

    /// Connect and authenticate, or fail — there is no half-open state worth
    /// handing back.
    init?() {
        // `unix:path=…` is what a session bus is in practice;
        // `unix:abstract=…` appears on older systems, in the Linux-only
        // abstract namespace, which is a leading NUL in the socket path.
        guard let address = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] else {
            return nil
        }
        var abstract = false
        var path: String? = nil
        for field in address.split(separator: ",") {
            if field.hasPrefix("unix:path=") {
                path = String(field.dropFirst("unix:path=".count))
            } else if field.hasPrefix("unix:abstract=") {
                path = String(field.dropFirst("unix:abstract=".count))
                abstract = true
            }
        }
        guard let socketPath = path else { return nil }

        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.utf8)
        // One byte for the leading NUL of an abstract name, one for the
        // terminator of a filesystem one — either way the name must fit.
        guard utf8.count + 1 <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Glibc.close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.bindMemory(to: UInt8.self)
            var index = 0
            if abstract {
                base[0] = 0
                index = 1
            }
            for byte in utf8 {
                base[index] = byte
                index += 1
            }
        }

        // Never block the launch on an unresponsive bus.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, authenticate() else {
            Glibc.close(fd)
            return nil
        }
    }

    func close() { Glibc.close(fd) }

    /// SASL EXTERNAL: the kernel already told the bus who is on the other end
    /// of the socket, so the "credential" is just this process's uid, in hex.
    /// The leading NUL is required before any of it.
    private func authenticate() -> Bool {
        guard write([0]) else { return false }
        let uid = String(getuid())
        let hex = uid.utf8.map { String(format: "%02x", $0) }.joined()
        guard write(Array("AUTH EXTERNAL \(hex)\r\n".utf8)),
              let reply = readLine(), reply.hasPrefix("OK") else { return false }
        return write(Array("BEGIN\r\n".utf8))
    }

    private var nextSerial: UInt32 = 1

    /// One method call, returning the `u` inside the reply's variant.
    ///
    /// `Hello` first, once: the bus refuses every other message until the
    /// connection has a name.
    func call(
        destination: String,
        path: String,
        interface: String,
        member: String,
        arguments: [String]
    ) -> UInt32? {
        if nextSerial == 1 {
            guard send(
                destination: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus",
                member: "Hello",
                arguments: []
            ) != nil else { return nil }
        }
        guard let serial = send(
            destination: destination,
            path: path,
            interface: interface,
            member: member,
            arguments: arguments
        ) else { return nil }
        return awaitReply(to: serial)
    }

    private func send(
        destination: String,
        path: String,
        interface: String,
        member: String,
        arguments: [String]
    ) -> UInt32? {
        var body = Writer()
        for argument in arguments { body.string(argument) }

        let serial = nextSerial
        nextSerial += 1

        var message = Writer()
        message.byte(0x6c)                      // 'l' — little-endian
        message.byte(1)                         // METHOD_CALL
        message.byte(0)                         // no flags
        message.byte(1)                         // protocol version
        message.uint32(UInt32(body.bytes.count))
        message.uint32(serial)

        // The header fields, as an array of (byte, variant). Its length counts
        // the contents only, so it is written once the contents are laid out.
        var fields = Writer()
        func field(_ code: UInt8, _ type: String, _ value: String) {
            fields.pad(to: 8)                   // every struct starts 8-aligned
            fields.byte(code)
            fields.signature(type)
            fields.string(value)
        }
        field(1, "o", path)
        field(6, "s", destination)
        field(2, "s", interface)
        field(3, "s", member)
        if !arguments.isEmpty {
            fields.pad(to: 8)
            fields.byte(8)                      // SIGNATURE
            fields.signature("g")
            fields.signature(String(repeating: "s", count: arguments.count))
        }

        message.uint32(UInt32(fields.bytes.count))
        message.bytes.append(contentsOf: fields.bytes)
        message.pad(to: 8)                      // the body is 8-aligned
        message.bytes.append(contentsOf: body.bytes)

        return write(message.bytes) ? serial : nil
    }

    /// Read messages until the reply to `serial` turns up.
    ///
    /// Not simply "the next message": the bus interleaves signals — a
    /// `NameAcquired` arrives unbidden right after `Hello` — so the
    /// REPLY_SERIAL field is what identifies the answer.
    private func awaitReply(to serial: UInt32) -> UInt32? {
        for _ in 0..<16 {
            guard let fixed = read(count: 16) else { return nil }
            let littleEndian = fixed[0] == 0x6c
            var header = Reader(fixed, littleEndian: littleEndian)
            _ = header.byte()
            let type = header.byte() ?? 0
            _ = header.byte()
            _ = header.byte()
            guard let bodyLength = header.uint32(),
                  header.uint32() != nil,                 // this message's serial
                  let fieldsLength = header.uint32() else { return nil }

            // The fields array ends 8-aligned, and the body starts there.
            let padding = (8 - Int(fieldsLength) % 8) % 8
            guard let rest = read(count: Int(fieldsLength) + padding + Int(bodyLength)) else {
                return nil
            }

            var fields = Reader(Array(rest[0..<Int(fieldsLength)]), littleEndian: littleEndian)
            var replySerial: UInt32? = nil
            var bodySignature: String? = nil
            while fields.offset < fields.bytes.count {
                fields.pad(to: 8)
                guard let code = fields.byte(), let type = fields.signature() else { break }
                switch (code, type) {
                case (5, "u"): replySerial = fields.uint32()
                case (8, "g"): bodySignature = fields.signature()
                case (_, "s"), (_, "o"): _ = fields.string()
                case (_, "g"): _ = fields.signature()
                case (_, "u"): _ = fields.uint32()
                default: return nil    // a type this does not model: give up
                }
            }

            guard replySerial == serial else { continue }
            // 3 is ERROR — a portal without this method, most likely, and the
            // caller has another name to try.
            guard type != 3, bodySignature == "v" else { return nil }

            var body = Reader(
                Array(rest[(Int(fieldsLength) + padding)...]),
                littleEndian: littleEndian
            )
            return body.variantUInt32()
        }
        return nil
    }

    // MARK: Socket

    private func write(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes {
                Glibc.write(fd, $0.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }

    private func read(count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes {
                Glibc.read(fd, $0.baseAddress!.advanced(by: filled), count - filled)
            }
            guard n > 0 else { return nil }
            filled += n
        }
        return buffer
    }

    /// The auth handshake is line-based text, before any of the above applies.
    private func readLine() -> String? {
        var line = [UInt8]()
        while line.count < 512 {
            guard let byte = read(count: 1)?.first else { return nil }
            if byte == 0x0a {                   // \n, after the \r
                if line.last == 0x0d { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            line.append(byte)
        }
        return nil
    }
}
#endif
