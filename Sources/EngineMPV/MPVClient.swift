#if canImport(Libmpv) && canImport(UIKit)
import Foundation
import Libmpv

/// Thin, thread-safe wrapper around a single `mpv_handle`.
///
/// libmpv's client API is thread-safe, so both the `@MainActor` engine (issuing
/// commands / property writes) and the background event-drain queue (reading
/// events / properties) call through this one object. It is therefore
/// `@unchecked Sendable`: it owns a raw `OpaquePointer` that the compiler can't
/// reason about, but every entry point funnels into the inherently thread-safe
/// libmpv handle. Keeping all C interop here lets the engine itself stay clean
/// Swift under `-strict-concurrency=complete`.
final class MPVClient: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    /// Bumped on every `create()`. A background drain binds the generation it
    /// started on and exits the moment it changes, so a stale drain from a prior
    /// session can never latch onto a freshly-created handle (the same
    /// `MPVClient` is reused across `load()`/`stop()`).
    private var generation: UInt64 = 0

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return handle != nil
    }

    /// Creates the underlying handle (uninitialized — set options, then call
    /// `initialize()`).
    @discardableResult
    func create() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard handle == nil else { return true }
        handle = mpv_create()
        if handle != nil { generation &+= 1 }
        return handle != nil
    }

    func initialize() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return -1 }
        return mpv_initialize(handle)
    }

    /// Runs `mpv_initialize` off the main queue. This avoids forcing renderer
    /// bring-up in the same main-thread turn as SwiftUI layout reconciliation.
    func initializeAsync() async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.initialize())
            }
        }
    }

    /// Tears the handle down. After this the client is inert until `create()`.
    func destroy() {
        lock.lock()
        let h = handle
        handle = nil
        // Unregister the wakeup callback *before* terminating so no further
        // wakeups can be delivered referencing a soon-to-be-freed owner.
        if let h { mpv_set_wakeup_callback(h, nil, nil) }
        lock.unlock()
        if let h { mpv_terminate_destroy(h) }
    }

    // MARK: Options / properties

    @discardableResult
    func setOptionString(_ name: String, _ value: String) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return -1 }
        return mpv_set_option_string(handle, name, value)
    }

    /// Sets the integer `wid` option (the render surface pointer) before init.
    @discardableResult
    func setWindowID(_ pointer: Int64) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return -1 }
        var value = pointer
        return mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &value)
    }

    @discardableResult
    func setPropertyString(_ name: String, _ value: String) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return -1 }
        return mpv_set_property_string(handle, name, value)
    }

    @discardableResult
    func setFlag(_ name: String, _ value: Bool) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return -1 }
        var flag: Int32 = value ? 1 : 0
        return mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
    }

    func getDouble(_ name: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return 0 }
        var value = Double()
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return 0 }
        return value
    }

    func getInt(_ name: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        var value = Int64()
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }

    func getFlag(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return false }
        var value = Int64()
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return false }
        return value > 0
    }

    func getString(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        guard let cstr = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    // MARK: Observation / commands

    func observeDouble(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        mpv_observe_property(handle, 0, name, MPV_FORMAT_DOUBLE)
    }

    func observeFlag(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        mpv_observe_property(handle, 0, name, MPV_FORMAT_FLAG)
    }

    func requestLogMessages(_ level: String) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        mpv_request_log_messages(handle, level)
    }

    /// Issues an mpv command (`loadfile`, `seek`, …) with a NULL-terminated argv.
    @discardableResult
    func command(_ args: [String]) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return -1 }
        // `strdup` gives mutable copies we own (and must `free`); mpv_command wants
        // a NULL-terminated `const char **`, so build a parallel const view.
        let owned: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer { for p in owned { free(p) } }
        var cargs: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        cargs.append(nil)
        return cargs.withUnsafeMutableBufferPointer { buf in
            mpv_command(handle, buf.baseAddress)
        }
    }

    /// Registers a C wakeup callback. `ctx` is an unretained pointer to the owner;
    /// the callback fires from an arbitrary thread.
    func setWakeup(ctx: UnsafeMutableRawPointer, callback: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        mpv_set_wakeup_callback(handle, callback, ctx)
    }

    /// Drains all currently-queued events, invoking `onEvent` for each. Returns
    /// when the queue is empty (`MPV_EVENT_NONE`). Safe to call off the main
    /// thread; that's the point.
    func drainEvents(_ onEvent: (MPVEvent) -> Void) {
        lock.lock()
        let boundGen = generation
        let alive = handle != nil
        lock.unlock()
        guard alive else { return }

        while true {
            lock.lock()
            // Bail if the handle was torn down, or replaced by a newer session
            // (generation bumped) — otherwise we'd consume the new session's
            // events from this stale drain.
            guard let handle, generation == boundGen else { lock.unlock(); return }
            let eventPtr = mpv_wait_event(handle, 0)
            guard let raw = eventPtr?.pointee, raw.event_id != MPV_EVENT_NONE else {
                lock.unlock()
                return
            }
            // `mpv_wait_event` returns a pointer into mpv-owned storage that is
            // only valid until the next `mpv_wait_event` / `mpv_terminate_destroy`.
            // Fully project it into a `Sendable` `MPVEvent` *while still holding the
            // lock*, so a concurrent `destroy()` can't free it mid-read.
            let parsed = Self.parse(raw)
            let isShutdown = raw.event_id == MPV_EVENT_SHUTDOWN
            lock.unlock()

            // `onEvent` only marshals to the main actor; it never touches mpv, so
            // it's safe (and avoids holding the lock across the hop).
            if let parsed { onEvent(parsed) }
            if isShutdown { return }
        }
    }

    /// Projects a raw mpv event into a `Sendable` value. Must be called while the
    /// lock is held (it dereferences `event.data`, which is mpv-owned).
    private static func parse(_ event: mpv_event) -> MPVEvent? {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            if let prop = UnsafePointer<mpv_event_property>(OpaquePointer(event.data))?.pointee {
                return .propertyChanged(String(cString: prop.name))
            }
            return nil
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_END_FILE:
            if let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.data))?.pointee {
                // `error` is negative for a real failure; `reason == ERROR`
                // also signals a decode/IO failure rather than a clean EOF.
                let isError = endFile.error < 0 || endFile.reason == MPV_END_FILE_REASON_ERROR
                // A clean playthrough to the end (not a user stop / quit / file
                // switch), so the owner can react (e.g. dismiss a finished trailer).
                let isEOF = endFile.reason == MPV_END_FILE_REASON_EOF
                return .endFile(isError: isError, isEOF: isEOF)
            }
            return .endFile(isError: false, isEOF: false)
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        default:
            return nil
        }
    }
}

/// A minimal, `Sendable` projection of the mpv events the engine cares about.
enum MPVEvent: Sendable {
    case propertyChanged(String)
    case fileLoaded
    case endFile(isError: Bool, isEOF: Bool)
    case shutdown
}
#endif
