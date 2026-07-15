#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
#if canImport(Darwin)
import Darwin
#endif

/// Live, on-device Home performance sampler for the ``HomePerfOverlay`` HUD.
///
/// Drives a `CADisplayLink` to measure **actual frame pacing** while browsing Home
/// — the truest signal of smoothness on older Apple TV hardware. Per frame it
/// accumulates hitches (frames that blow the display's budget) and a smoothed FPS,
/// then publishes a snapshot only a few times a second (so the HUD itself never
/// becomes the thing causing churn). Also samples thermal state, memory footprint,
/// and the device model, and reads the latest curate/artwork timings from
/// ``HomePerfDiagnostics``.
///
/// Entirely inert until ``start()`` is called (the HUD does so only when its
/// Settings toggle is on), so shipped runs pay nothing.
@MainActor
@Observable
public final class HomePerfSampler {
    // Published snapshot (updated ~4×/sec while running).
    public private(set) var fps: Double = 0
    public private(set) var hitchesTotal: Int = 0
    public private(set) var hitchesPerSecond: Double = 0
    public private(set) var worstFrameMs: Double = 0
    public private(set) var thermal: ProcessInfo.ThermalState = .nominal
    public private(set) var memoryMB: Double = 0
    public private(set) var curateMs: Double?
    public private(set) var artworkMs: Double?

    public let deviceModel: String = HomePerfSampler.machineIdentifier()

    private var link: CADisplayLink?
    private var proxy: DisplayLinkProxy?

    private var lastTimestamp: CFTimeInterval = 0
    private var fpsEMA: Double = 0
    private var windowHitches: Int = 0
    private var windowWorstMs: Double = 0
    private var windowStart: CFTimeInterval = 0
    // Separate ~1s window for the stdout stream so remote `--console` capture stays
    // readable (one line/sec) with accurate per-second hitch counts.
    private var emitHitches: Int = 0
    private var emitWorstMs: Double = 0
    private var emitStart: CFTimeInterval = 0

    public nonisolated init() {}

    public func start() {
        guard link == nil else { return }
        lastTimestamp = 0
        fpsEMA = 0
        windowHitches = 0
        windowWorstMs = 0
        windowStart = 0
        emitHitches = 0
        emitWorstMs = 0
        emitStart = 0
        let proxy = DisplayLinkProxy { [weak self] link in
            self?.tick(link)
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step(_:)))
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.link = link
    }

    public func stop() {
        link?.invalidate()
        link = nil
        proxy = nil
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        // Nominal frame duration for this display (fallback to 60 Hz).
        let nominal = link.duration > 0 ? link.duration : 1.0 / 60.0

        if lastTimestamp > 0 {
            let delta = now - lastTimestamp
            if delta > 0 {
                let instantaneousFPS = 1.0 / delta
                // Light EMA so the number reads steadily rather than jittering.
                fpsEMA = fpsEMA == 0 ? instantaneousFPS : (fpsEMA * 0.9 + instantaneousFPS * 0.1)
                // A hitch is a frame that ran meaningfully past the display budget.
                if delta > nominal * 1.5 {
                    windowHitches += 1
                    emitHitches += 1
                }
                let frameMs = delta * 1_000
                windowWorstMs = max(windowWorstMs, frameMs)
                emitWorstMs = max(emitWorstMs, frameMs)
            }
        }
        lastTimestamp = now

        if windowStart == 0 { windowStart = now }
        let windowElapsed = now - windowStart
        if windowElapsed >= 0.25 {
            publish(windowElapsed: windowElapsed)
            windowStart = now
            windowHitches = 0
            windowWorstMs = 0
        }

        if emitStart == 0 { emitStart = now }
        let emitElapsed = now - emitStart
        if emitElapsed >= 1.0 {
            emitStreamLine(windowElapsed: emitElapsed)
            emitStart = now
            emitHitches = 0
            emitWorstMs = 0
        }
    }

    private func publish(windowElapsed: CFTimeInterval) {
        fps = fpsEMA
        hitchesTotal += windowHitches
        hitchesPerSecond = windowElapsed > 0 ? Double(windowHitches) / windowElapsed : 0
        worstFrameMs = windowWorstMs
        thermal = ProcessInfo.processInfo.thermalState
        if let mb = Self.memoryFootprintMB() { memoryMB = mb }
        curateMs = HomePerfDiagnostics.lastCurateMs
        artworkMs = HomePerfDiagnostics.lastArtworkMs
    }

    /// One compact per-second line for remote `--console` capture. Cheap and a
    /// no-op unless launched with `PLZPERF_STDOUT=1` (the string is only built then).
    private func emitStreamLine(windowElapsed: CFTimeInterval) {
        guard HomePerfDiagnostics.isStdoutMirrorEnabled else { return }
        let perSecond = windowElapsed > 0 ? Double(emitHitches) / windowElapsed : 0
        let curate = HomePerfDiagnostics.lastCurateMs.map { String(format: "%.0f", $0) } ?? "-"
        let art = HomePerfDiagnostics.lastArtworkMs.map { String(format: "%.0f", $0) } ?? "-"
        HomePerfDiagnostics.emitLine(
            String(
                format: "fps=%.0f hitch/s=%.1f total=%d worst=%.0fms thermal=%@ mem=%.0fMB curate=%@ms art=%@ms dev=%@",
                fpsEMA,
                perSecond,
                hitchesTotal,
                emitWorstMs,
                Self.thermalToken(ProcessInfo.processInfo.thermalState),
                Self.memoryFootprintMB() ?? 0,
                curate,
                art,
                deviceModel
            )
        )
    }

    private static func thermalToken(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - System probes

    private static func memoryFootprintMB() -> Double? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
        #else
        return nil
        #endif
    }

    private static func machineIdentifier() -> String {
        #if canImport(Darwin)
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "Apple TV" : machine
        #else
        return "Apple TV"
        #endif
    }
}

/// NSObject shim so the `CADisplayLink` target/selector requirement doesn't force
/// the `@Observable` sampler to subclass NSObject.
private final class DisplayLinkProxy: NSObject {
    private let handler: (CADisplayLink) -> Void

    init(handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
    }

    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated { handler(link) }
    }
}
#endif
