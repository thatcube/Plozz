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
}
