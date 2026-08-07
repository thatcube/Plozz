#if canImport(AVFoundation)
import Foundation
import Observation
import SwiftUI

/// Which display handshake a black veil is hiding.
///
/// The two differ in cost and in how reliably the TV reports them, so they get
/// different hold budgets — and each is independently user-toggleable, since
/// whether either handshake happens at all depends on the viewer's tvOS
/// *Match Content* settings, which no API exposes.
public enum DisplayTransitionKind: Sendable, Equatable {
    /// SDR ⇄ HDR10 / HLG / Dolby Vision (tvOS "Match Dynamic Range"). Expensive:
    /// real TVs can take 1–3s and some switch physically after reporting settle.
    case dynamicRange
    /// A refresh-rate change only (tvOS "Match Frame Rate") — e.g. dropping from
    /// 23.976 Hz back to the UI's rate on exit. Cheaper, and often reported late
    /// or not at all, so it gets a tighter hold.
    case frameRate
}

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
        /// The no-settle fallback for a **frame-rate-only** exit. Trimmed against
        /// `noSettleHold` because a refresh-rate re-sync is the quicker of the two
        /// blanks — but still comfortably longer than that blank, which is the
        /// whole point: the fade has to start *after* the panel is back.
        public var frameRateNoSettleHold: TimeInterval = 2.0
        /// Ceiling on the post-settle hold for a **frame-rate-only** exit, so a
        /// slow-reporting TV can't stretch an SDR exit as far as a Dolby Vision
        /// one. Note the FLOOR (`minPostSettle`) is deliberately *not* specialised:
        /// it's what keeps the fade behind the panel blank on a TV that reports
        /// settle early, and cutting it is exactly what made the picture snap in.
        public var frameRateMaxPostSettle: TimeInterval = 1.6
        /// How long the veil takes to fade back out after a dynamic-range exit.
        /// The panel is still visibly settling underneath, which carries a lot of
        /// the transition, so a fairly quick fade already feels smooth.
        public var fadeOut: TimeInterval = 0.4
        /// How long the veil takes to fade back out after a **frame-rate-only**
        /// exit. Slower on purpose: nothing is visibly settling underneath here,
        /// so the fade *is* the whole transition. At the dynamic-range duration
        /// the picture reads as snapping in rather than resolving out of black.
        public var frameRateFadeOut: TimeInterval = 0.7
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
            frameRateNoSettleHold: TimeInterval = 2.0,
            frameRateMaxPostSettle: TimeInterval = 1.6,
            fadeOut: TimeInterval = 0.4,
            frameRateFadeOut: TimeInterval = 0.7,
            minPostSettle: TimeInterval = 0.8,
            maxPostSettle: TimeInterval = 2.2,
            settleLagMultiplier: Double = 1.0,
            safetyCap: TimeInterval = 6.0
        ) {
            self.noSettleHold = noSettleHold
            self.frameRateNoSettleHold = frameRateNoSettleHold
            self.frameRateMaxPostSettle = frameRateMaxPostSettle
            self.fadeOut = fadeOut
            self.frameRateFadeOut = frameRateFadeOut
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
    /// Which handshake the current engagement is hiding, so the no-settle
    /// fallback and the post-settle ceiling match its real cost.
    private var engagedKind: DisplayTransitionKind = .dynamicRange

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

    /// How long the *fade-out* should take for the exit currently being covered.
    /// The root view reads this for its animation, so the reveal is paced to the
    /// handshake being hidden rather than one duration for both. Kept after the
    /// veil lowers so the falling-edge animation still reads the right value.
    public var fadeOutDuration: TimeInterval {
        engagedKind == .frameRate ? configuration.frameRateFadeOut : configuration.fadeOut
    }

    /// Raise the window veil to solid black and start the safety machinery. Call
    /// this at the *start* of an exit, before dismissing the player, so the black
    /// layer is already in place beneath the player's `fullScreenCover` and keeps
    /// covering the screen once the player tears down into Home.
    ///
    /// `kind` trims the tail of a frame-rate-only exit — a shorter blind fallback,
    /// a lower post-settle ceiling and a quicker fade. The post-settle *floor* is
    /// shared: it's what keeps the fade behind the panel blank, and specialising
    /// it is what previously made the picture snap in.
    ///
    /// Idempotent within a single exit: re-engaging while already engaged restarts
    /// the timers from now (e.g. a second leave gesture) rather than stacking them.
    public func engage(kind: DisplayTransitionKind = .dynamicRange) {
        cancelTasks()
        isEngaged = true
        veilOpacity = 1
        engagedAt = now()
        engagedKind = kind

        let sleep = self.sleep
        // No-settle fallback: if the display never reports a mode-switch-end, clear
        // after a hold that still covers a typical physical switch.
        let fallback = kind == .frameRate
            ? configuration.frameRateNoSettleHold
            : configuration.noSettleHold
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
        let buffer = postSettleHold(forGap: gap, kind: engagedKind)

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
    /// can't hang the exit. A frame-rate-only exit lowers the *ceiling* only — the
    /// floor is shared, since that's what keeps the fade behind the panel blank.
    /// Pure and `static`-like for direct unit testing.
    public func postSettleHold(
        forGap gap: TimeInterval,
        kind: DisplayTransitionKind = .dynamicRange
    ) -> TimeInterval {
        let scaled = gap * configuration.settleLagMultiplier
        let ceiling = kind == .frameRate
            ? configuration.frameRateMaxPostSettle
            : configuration.maxPostSettle
        return min(ceiling, max(configuration.minPostSettle, scaled))
    }

    /// Drop the veil now and cancel all pending timers. Safe to call repeatedly.
    ///
    /// The fade-out is applied HERE, as an explicit transaction, rather than being
    /// left to an `.animation(_:value:)` modifier at the call site. The veil has to
    /// snap to black instantly on the way in but ease out on the way back, and
    /// expressing that as a modifier means a conditional animation that silently
    /// degrades to a hard cut if the condition is ever evaluated against the wrong
    /// edge. Owning the animation at the one place that lowers the veil makes the
    /// fade unconditional — and the duration is chosen per transition kind.
    public func lower() {
        cancelTasks()
        isEngaged = false
        guard veilOpacity != 0 else { return }
        withAnimation(.easeInOut(duration: fadeOutDuration)) {
            veilOpacity = 0
        }
    }

    private func cancelTasks() {
        capTask?.cancel()
        capTask = nil
        holdTask?.cancel()
        holdTask = nil
    }
}
#endif
