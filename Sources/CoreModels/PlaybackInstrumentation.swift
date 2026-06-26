import Foundation

/// Process-wide, lightweight instrumentation the playback diagnostics overlay
/// uses to surface **resource accumulation (leaks)** on-device.
///
/// Motivation: playback that is silky-smooth on a fresh launch but degrades the
/// longer the app stays open — and recovers on a full app restart — is the
/// signature of an in-process leak (engines / view-models / memory that never
/// get released). These counters make that visible from the couch: if the live
/// instance counts climb past one and never fall back as you leave and re-enter
/// the player, the leaked type is named directly, and the memory footprint shows
/// the cumulative cost.
///
/// The counters are deliberately cheap: a single lock-guarded dictionary updated
/// in the `init`/`deinit` of the playback engines and the player view-model. They
/// run regardless of whether the overlay is shown (an atomic-ish increment is
/// negligible), so the very first toggle of the overlay already reflects history.
public enum PlaybackInstrumentation {
    /// The instance kinds tracked for leak detection.
    public enum Kind: String, Sendable, CaseIterable {
        /// `PlayerViewModel` — one per player presentation.
        case viewModel
        /// `NativeVideoEngine` (AVPlayer).
        case nativeEngine
        /// `MPVVideoEngine` (libmpv / gpu-next).
        case mpvEngine
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [Kind: Int] = [:]

    /// Records a new live instance of `kind` (call from `init`).
    public static func increment(_ kind: Kind) {
        lock.lock()
        counts[kind, default: 0] += 1
        lock.unlock()
    }

    /// Records the release of an instance of `kind` (call from `deinit`).
    public static func decrement(_ kind: Kind) {
        lock.lock()
        counts[kind, default: 0] -= 1
        lock.unlock()
    }

    /// The current number of live instances of `kind`.
    public static func count(_ kind: Kind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[kind, default: 0]
    }

    /// Snapshot of all live counts.
    public static func snapshot() -> [Kind: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// Current resident memory of the app process (Mach `phys_footprint`, the
    /// metric the OS uses for Jetsam), in bytes — or `nil` if unavailable.
    public static func memoryFootprintBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }
}
