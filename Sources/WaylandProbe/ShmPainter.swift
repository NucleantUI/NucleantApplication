//
//  ShmPainter.swift
//  WaylandProbe
//
//  Attaches a plain CPU-drawn buffer to the probe's surface every frame.
//
//  Not a renderer, and not something Platform_Linux needs — this exists
//  because of one protocol rule: a Wayland surface is not *mapped* until a
//  buffer has been attached to it, and an unmapped surface never gets a
//  `wl_surface.frame` callback. Without a buffer the probe can only ever
//  exercise the fallback timer, so the frame-callback path — the actual
//  displaylink equivalent — would go untested. Attaching a solid colour is
//  the cheapest way to make the compositor treat the window as real.
//
//  It also makes the window visible, which is the difference between "the
//  probe printed some numbers" and "I can see it resize".
//
#if os(Linux)
import CWayland
import Glibc

/// Binds `wl_shm` off its own registry — the probe is a client of the same
/// connection as `Platform_Linux`, not a part of it, so it does its own
/// discovery rather than asking that module to carry an shm dependency it
/// has no use for.
final class ShmPainter {

    private let display: OpaquePointer
    private let surface: OpaquePointer

    private var shm: OpaquePointer?
    private var pool: OpaquePointer?
    private var buffer: OpaquePointer?

    private var fd: Int32 = -1
    private var pixels: UnsafeMutableRawPointer?
    private var capacity = 0

    private var width: Int32 = 0
    private var height: Int32 = 0

    private var registryListener: UnsafeMutablePointer<wl_registry_listener>?
    private var shmListener: UnsafeMutablePointer<wl_shm_listener>?

    init?(display: OpaquePointer, surface: OpaquePointer) {
        self.display = display
        self.surface = surface

        let registry = wl_display_get_registry(display)
        var listener = wl_registry_listener()
        listener.global = { data, registry, name, interface, version in
            guard let data, let registry, let interface else { return }
            let descriptor = nucleant_wl_shm_interface()!
            guard String(cString: interface) == String(cString: descriptor.pointee.name) else { return }
            let me = Unmanaged<ShmPainter>.fromOpaque(data).takeUnretainedValue()
            let bound = min(version, UInt32(descriptor.pointee.version))
            me.shm = wl_registry_bind(registry, name, descriptor, bound).map(OpaquePointer.init)
        }
        listener.global_remove = { _, _, _ in }
        registryListener = UnsafeMutablePointer<wl_registry_listener>.allocate(capacity: 1)
        registryListener!.initialize(to: listener)
        wl_registry_add_listener(registry, registryListener, Unmanaged.passUnretained(self).toOpaque())
        wl_display_roundtrip(display)

        guard let shm else {
            print("no wl_shm — cannot paint")
            return nil
        }
        // The format event is advertised unconditionally, so the slot has to
        // be non-null even though XRGB8888 is mandatory and always present.
        var formats = wl_shm_listener()
        formats.format = { _, _, _ in }
        shmListener = UnsafeMutablePointer<wl_shm_listener>.allocate(capacity: 1)
        shmListener!.initialize(to: formats)
        wl_shm_add_listener(shm, shmListener, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Draws and attaches. Safe to call every frame; the shared mapping is
    /// only rebuilt when the size actually changes.
    func paint(width newWidth: Int32, height newHeight: Int32, frame: Int) {
        guard newWidth > 0, newHeight > 0 else { return }
        if newWidth != width || newHeight != height {
            guard resize(width: newWidth, height: newHeight) else { return }
        }
        guard let pixels, let buffer else { return }

        // A slow colour cycle, so a still window is visibly still being
        // driven rather than just sitting there.
        let phase = Double(frame) * 0.02
        let r = UInt32((sin(phase) * 0.5 + 0.5) * 90 + 20)
        let g = UInt32((sin(phase + 2.0) * 0.5 + 0.5) * 90 + 20)
        let b = UInt32((sin(phase + 4.0) * 0.5 + 0.5) * 90 + 40)
        let colour = (r << 16) | (g << 8) | b

        let words = pixels.assumingMemoryBound(to: UInt32.self)
        for index in 0..<(Int(width) * Int(height)) {
            words[index] = colour
        }

        wl_surface_attach(surface, buffer, 0, 0)
        wl_surface_damage_buffer(surface, 0, 0, width, height)
        wl_surface_commit(surface)
    }

    private func resize(width newWidth: Int32, height newHeight: Int32) -> Bool {
        guard let shm else { return false }

        let stride = Int(newWidth) * 4
        let size = stride * Int(newHeight)

        if let buffer { wl_buffer_destroy(buffer) }
        buffer = nil
        if let pool { wl_shm_pool_destroy(pool) }
        pool = nil
        if let pixels, capacity > 0 { munmap(pixels, capacity) }
        pixels = nil
        if fd >= 0 { close(fd) }
        fd = -1

        // An anonymous file in XDG_RUNTIME_DIR, unlinked straight away: the
        // compositor gets the fd, nothing gets a path.
        let runtimeDir = ProcessInfo.runtimeDirectory
        var template = Array("\(runtimeDir)/nucleant-probe-XXXXXX".utf8CString)
        let created = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard created >= 0 else {
            print("mkstemp failed: \(String(cString: strerror(errno)))")
            return false
        }
        fd = created
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }

        guard ftruncate(fd, off_t(size)) == 0 else {
            print("ftruncate failed: \(String(cString: strerror(errno)))")
            return false
        }
        let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED else {
            print("mmap failed: \(String(cString: strerror(errno)))")
            return false
        }
        pixels = mapped
        capacity = size

        pool = wl_shm_create_pool(shm, fd, Int32(size))
        guard let pool else { return false }
        buffer = wl_shm_pool_create_buffer(
            pool, 0, newWidth, newHeight, Int32(stride),
            WL_SHM_FORMAT_XRGB8888.rawValue
        )
        guard buffer != nil else { return false }

        width = newWidth
        height = newHeight
        return true
    }
}

private enum ProcessInfo {
    static var runtimeDirectory: String {
        if let dir = getenv("XDG_RUNTIME_DIR") { return String(cString: dir) }
        return "/tmp"
    }
}
#endif
