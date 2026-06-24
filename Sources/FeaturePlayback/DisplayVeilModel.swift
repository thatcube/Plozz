#if canImport(AVFoundation)
import Foundation
import Observation

/// A **window / app-root** black veil that survives the player's dismiss into Home
/// so it can cover the TV's physical HDMI display-mode switch (HDR/Dolby Vision →
/// SDR) when the user leaves a movie.
///
/// ## Why this exists separately from `HDRTransitionModel`
/// `HDRTransitionModel` owns the veil *inside* `PlayerView`. That veil is torn down
/// the instant the player is dismissed. On some real TVs the **physical** panel
/// switches its HDR/DV mode roughly a second *after* tvOS reports the switch
/// finished (`AVDisplayManagerModeSwitchEnd`) — and by then the user is already
/// back on Home with the player's veil gone, so they see Home and *then* a flash.
///
/// This model lives at the app root (above the player's `fullScreenCover`), so its
/// black layer keeps covering the screen through the dismiss → Home handoff and for
/// a buffer *past* the reported settle, hiding even a late physical switch.
///
/// ## Adaptive hold (snappy fast TVs, safe slow TVs)
/// A holdover past the reported settle would feel sluggish if it were a fixed,
/// generous value for everyone. Instead the post-settle hold **adapts**: a slow TV
/// both *reports* its settle late and *physically* switches late, so the gap between
/// `engage()` and the reported settle is a usable proxy for that TV's sluggishness.
/// We hold black for `clamp(gap * settleLagMultiplier, minPostSettle, maxPostSettle)`
/// after the settle — short for fast TVs, longer for slow ones.
///
/// ## Never stuck on black
/// Two guarantees bound the black, independent of any display callback:
///   * a **no-settle fallback** clears the veil if no settle signal ever arrives;
///   * an absolute **safety cap** clears it no matter what.
///
/// Provider-agnostic: it keys off display events, not Plex/Jellyfin specifics.
@MainActor
@Observable
public final class DisplayVeilModel {
    /// Veil opacity: `0` = clear (Home visible), `1` = solid black. The root view
    /// animates a black overlay to this value.
    public private(set) var veilOpacity: Double = 0

    /// True from `engage()` until the veil is lowered (settle+buffer, fallback, or
    /// cap). While engaged the veil is held fully black.
    public private(set) var isEngaged = false

    public struct Configuration: Sendable {
        /// Clears the veil this long after `engage()` if **no** settle signal ever
        /// arrives. Some TVs don't emit a clean mode-switch-end on HDR/DV → SDR, so
        /// this blind fallback must still cover a typical physical switch.
        public var noSettleHold: TimeInterval = 2.5
        /// Floor on the post-settle hold, so even a near-instant settle keeps black
        /// up long enough to hide a small physical lag (and avoids a flash on Home).
        public var minPostSettle: TimeInterval = 0.8
        /// Ceiling on the post-settle hold, so a very slow settle can't make the
        /// exit feel indefinitely laggy.
        public var maxPostSettle: TimeInterval = 2.2
        /// Multiplies the observed engage→settle gap to estimate how long *past* the
        /// reported settle the physical panel may still need.
        public var settleLagMultiplier: Double = 1.0
        /// Absolute cap on total black time from `engage()`. The last-resort net
        /// that guarantees the veil can never strand the user on a black screen.
        public var safetyCap: TimeInterval = 6.0
        public init(
            noSettleHold: TimeInterval = 2.5,
            minPostSettle: TimeInterval = 0.8,
            maxPostSettle: TimeInterval = 2.2,
            settleLagMultiplier: Double = 1.0,
            safetyCap: TimeInterval = 6.0
        ) {
            self.noSettleHold = noSettleHold
            self.minPostSettle = minPostSettle
            self.maxPostSettle = maxPostSettle
            self.settleLagMultiplier = settleLagMultiplier
            self.safetyCap = safetyCap
        }
    }

    public let configuration: Configuration
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> TimeInterval

    /// Absolute cap timer — always clears the veil, armed once per `engage()`.
    private var capTask: Task<Void, Never>?
    /// The active "lower soon" timer: either the no-settle fallback (armed at
    /// `engage()`) or the adaptive post-settle hold (re-armed on each settle).
    private var holdTask: Task<Void, Never>?
    /// Wall-clock-ish time the current engagement started, for measuring the
    /// engage→settle gap that drives the adaptive hold.
    private var engagedAt: TimeInterval = 0

    public init(
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.configuration = configuration
        self.now = now
        self.sleep = sleep
    }

    /// True while the veil is covering (any non-trivial opacity).
    public var isVeiled: Bool { veilOpacity > 0 }

    /// Raise the window veil to solid black and start the safety machinery. Call
    /// this at the *start* of an HDR/DV exit, before dismissing the player, so the
    /// black layer is already in place beneath the player's `fullScreenCover` and
    /// keeps covering the screen once the player tears down into Home.
    ///
    /// Idempotent within a single exit: re-engaging while already engaged restarts
    /// the timers from now (e.g. a second leave gesture) rather than stacking them.
    public func engage() {
        cancelTasks()
        isEngaged = true
        veilOpacity = 1
        engagedAt = now()

        let sleep = self.sleep
        // No-settle fallback: if the display never reports a mode-switch-end, clear
        // after a hold that still covers a typical physical switch.
        let fallback = configuration.noSettleHold
        holdTask = Task { @MainActor [weak self] in
            try? await sleep(fallback)
            guard !Task.isCancelled else { return }
            self?.lower()
        }
        // Absolute cap: clears no matter what, so black can never get stuck.
        let cap = configuration.safetyCap
        capTask = Task { @MainActor [weak self] in
            try? await sleep(cap)
            guard !Task.isCancelled else { return }
            self?.lower()
        }
    }

    /// The display reported it finished switching modes
    /// (`AVDisplayManagerModeSwitchEnd`). While engaged this (re)schedules the veil
    /// to lower after the **adaptive** post-settle hold; the absolute cap keeps
    /// running underneath. No-op when the veil isn't engaged (e.g. the enter-path
    /// settle, which the player's own `HDRTransitionModel` handles).
    public func displayDidSettle() {
        guard isEngaged else { return }
        let gap = max(0, now() - engagedAt)
        let buffer = postSettleHold(forGap: gap)

        // Replace whatever lower-timer is pending (the no-settle fallback, or an
        // earlier settle's hold) with one keyed off this — the latest — settle, so
        // a late second mode-switch-end extends coverage rather than cutting it.
        holdTask?.cancel()
        let sleep = self.sleep
        holdTask = Task { @MainActor [weak self] in
            try? await sleep(buffer)
            guard !Task.isCancelled else { return }
            self?.lower()
        }
    }

    /// The adaptive post-settle hold for a given engage→settle gap: proportional to
    /// the TV's observed sluggishness, clamped so fast TVs stay snappy and slow TVs
    /// can't hang the exit. Pure and `static`-like for direct unit testing.
    public func postSettleHold(forGap gap: TimeInterval) -> TimeInterval {
        let scaled = gap * configuration.settleLagMultiplier
        return min(configuration.maxPostSettle, max(configuration.minPostSettle, scaled))
    }

    /// Drop the veil now and cancel all pending timers. Safe to call repeatedly.
    public func lower() {
        cancelTasks()
        isEngaged = false
        veilOpacity = 0
    }

    private func cancelTasks() {
        capTask?.cancel()
        capTask = nil
        holdTask?.cancel()
        holdTask = nil
    }
}
#endif
