import Foundation

/// TEMPORARY on-device diagnostic logger (absolute timestamps) for tracing the
/// detail-page load. Writes to `Library/Caches/plzdetail.log`, truncating once
/// per launch. Thread-safe. REMOVE before shipping.
public enum DLog {
    private static let lock = NSLock()
    private static var started = false
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let launch = Date()

    private static var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("plzdetail.log")
    }

    public static func mark(_ line: @autoclosure () -> String) {
        let now = Date()
        let t = now.timeIntervalSince(launch)
        let text = String(format: "[%8.3f] %@\n", t, line())
        lock.lock(); defer { lock.unlock() }
        if !started {
            started = true
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: fileURL)
        }
        guard let handle, let data = text.data(using: .utf8) else { return }
        handle.write(data)
    }

    // MARK: - Crash capture (TEMPORARY)

    nonisolated(unsafe) private static var crashHandlerInstalled = false

    /// Installs an uncaught-exception + fatal-signal handler that appends the
    /// crashing backtrace to the same log file, so an on-device crash leaves a
    /// stack we can read after the fact. Best-effort (not strictly async-signal
    /// safe) — debug-only. REMOVE before shipping.
    public static func installCrashHandler() {
        lock.lock()
        if crashHandlerInstalled { lock.unlock(); return }
        crashHandlerInstalled = true
        lock.unlock()

        NSSetUncaughtExceptionHandler { exc in
            DLog.mark("💥 EXCEPTION \(exc.name.rawValue): \(exc.reason ?? "")")
            for frame in exc.callStackSymbols { DLog.mark("    \(frame)") }
        }

        for sig in [SIGABRT, SIGSEGV, SIGTRAP, SIGILL, SIGBUS, SIGFPE] as [Int32] {
            signal(sig) { received in
                DLog.mark("💥 SIGNAL \(received)")
                for frame in Thread.callStackSymbols { DLog.mark("    \(frame)") }
                signal(received, SIG_DFL)
                raise(received)
            }
        }
        mark("CRASH HANDLER installed")
    }

    // MARK: - Phase + heartbeat (detached: fires even if the main actor is blocked)

    nonisolated(unsafe) private static var phase = "idle"
    private static let phaseLock = NSLock()
    private static var phaseSince = Date()

    public static func setPhase(_ p: String) {
        phaseLock.lock()
        phase = p
        phaseSince = Date()
        phaseLock.unlock()
        mark("PHASE → \(p)")
    }

    /// Starts a detached heartbeat that logs the current phase every second until
    /// cancelled. Because it runs off the main actor, a heartbeat that keeps
    /// firing while the phase is stuck proves the work (not the main thread) is
    /// blocked; a heartbeat that STOPS firing proves the main thread is jammed.
    public static func startHeartbeat() -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                phaseLock.lock()
                let p = phase
                let ms = Date().timeIntervalSince(phaseSince) * 1000
                phaseLock.unlock()
                mark(String(format: "♥ phase=%@ (%.0fms)", p, ms))
            }
        }
    }

    // MARK: - Main-thread responsiveness probe

    nonisolated(unsafe) private static var mainPingStarted = false

    /// Starts a detached probe that measures how long it takes to hop onto the
    /// MainActor. If the main thread is jammed (sync work, render loop), the hop
    /// is delayed by seconds — proving that any `await` waiting to resume on the
    /// main actor is stuck on the MAIN THREAD, not on its own work. Call once at
    /// launch.
    public static func startMainPing() {
        lock.lock()
        if mainPingStarted { lock.unlock(); return }
        mainPingStarted = true
        lock.unlock()
        Task.detached {
            while true {
                let t0 = Date()
                await MainActor.run { _ = 0 }
                let dt = Date().timeIntervalSince(t0) * 1000
                if dt > 250 {
                    mark(String(format: "⚠️ MAIN STALL %.0fms", dt))
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        mark("MAIN PING started")
    }

    // MARK: - Dedicated-thread watchdog (cannot be starved by main OR pool)

    nonisolated(unsafe) private static var mainAlive: Int = 0
    private static let aliveLock = NSLock()
    nonisolated(unsafe) private static var watchdogStarted = false

    /// Current resident memory footprint (what Xcode's gauge shows), in MB.
    /// A steadily climbing value across navigation churn indicates a leak /
    /// unbounded retention.
    public static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    /// Live thread count for the process. A number that grows without bound under
    /// repeated navigation points to rogue tasks/threads being spawned and never
    /// finishing.
    public static func liveThreadCount() -> Int {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return -1 }
        defer {
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: OpaquePointer(threadList))), size)
        }
        return Int(threadCount)
    }

    /// Total process CPU usage (% across all cores; 100 == one core saturated).
    public static func cpuUsagePercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return -1 }
        defer {
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: OpaquePointer(threadList))), size)
        }
        var total = 0.0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if kr == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    private static func vitals() -> String {
        String(format: "mem=%.0fMB threads=%d cpu=%.0f%%",
               memoryFootprintMB(), liveThreadCount(), cpuUsagePercent())
    }

    /// Starts a real OS-thread watchdog (`userInteractive` QoS) that ticks every
    /// 500ms regardless of main-thread or cooperative-pool saturation, plus a
    /// main-runloop timer that bumps a liveness counter every 200ms. If the
    /// counter stops advancing the main thread is genuinely blocked, and the
    /// watchdog logs the stall together with memory / thread / CPU vitals — the
    /// one probe that stays alive when everything else (heartbeat, main-ping)
    /// goes dark, and the one that reveals a leak or rogue-thread storm. Call
    /// once at launch.
    public static func startWatchdog() {
        lock.lock()
        if watchdogStarted { lock.unlock(); return }
        watchdogStarted = true
        lock.unlock()

        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            aliveLock.lock(); mainAlive &+= 1; aliveLock.unlock()
        }
        RunLoop.main.add(timer, forMode: .common)

        let thread = Thread {
            var last = -1
            var blockedSince: Date?
            var tick = 0
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                tick += 1
                aliveLock.lock(); let cur = mainAlive; aliveLock.unlock()
                if cur == last {
                    if blockedSince == nil { blockedSince = Date() }
                    let ms = Date().timeIntervalSince(blockedSince!) * 1000
                    mark(String(format: "🛑 MAIN BLOCKED %.0fms  %@", ms, vitals()))
                } else {
                    if let since = blockedSince {
                        let ms = Date().timeIntervalSince(since) * 1000
                        mark(String(format: "✅ MAIN RESUMED after %.0fms  %@", ms, vitals()))
                        blockedSince = nil
                    }
                    // Periodic vitals (~every 2s) so a leak / thread storm shows as
                    // a trend even when the main thread is never blocked.
                    if tick % 4 == 0 { mark("📊 \(vitals())") }
                }
                last = cur
            }
        }
        thread.name = "plz-watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
        mark("WATCHDOG started")
    }
}
