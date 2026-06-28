import Foundation
import Darwin

/// Samples the process memory footprint that tvOS/iOS **jetsam** actually meters.
///
/// The local-remux cold far-seek crash is a `SIGKILL` (signal 9) the OS sends when
/// a task's `phys_footprint` crosses the per-app limit — NOT a Swift trap. To design
/// the bounded-cache / backpressure policy from data instead of a guess, the serving
/// path logs the real footprint a far seek drives (peak concurrent segments in flight,
/// peak `phys_footprint`), so the next on-device capture pinpoints what balloons:
/// the segment cache, AVPlayer's own 4K decode buffers, libav's probe buffers, or the
/// loopback origin's transient response copies.
///
/// `phys_footprint` is the value compared against the jetsam limit; `resident_size`
/// is the physically-mapped page count (a looser figure). We log both.
enum MemoryProbe {

    struct Footprint: Equatable {
        /// `phys_footprint` (bytes) — the number the OS compares against the per-app
        /// jetsam limit; what actually triggers the signal-9 kill.
        let physFootprint: Int64
        /// Resident size (bytes) — physical pages currently mapped to the task.
        let resident: Int64

        var physFootprintMB: Double { Double(physFootprint) / 1_048_576 }
        var residentMB: Double { Double(resident) / 1_048_576 }

        static let zero = Footprint(physFootprint: 0, resident: 0)
    }

    /// Samples the current task's memory footprint via Mach `TASK_VM_INFO`. Returns
    /// `.zero` if the query fails — telemetry must never throw or break serving.
    static func sample() -> Footprint {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return .zero }
        // `phys_footprint` lives near the end of task_vm_info; an older kernel that
        // returns a shorter struct leaves it zero (the resident_size still lands).
        return Footprint(physFootprint: Int64(info.phys_footprint),
                         resident: Int64(info.resident_size))
    }
}
