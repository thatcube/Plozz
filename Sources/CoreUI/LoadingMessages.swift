import Foundation
import Observation

/// A single quirky, on-brand loading message.
///
/// `text` doubles as the SwiftUI localization key: the view renders it through
/// `LocalizedStringKey(message.text)`, so the English copy here is shown as-is
/// until a string catalog provides a translation. `accessibilityText` lets a
/// message read differently for VoiceOver (e.g. spelling out an ellipsis as a
/// pause) without changing the on-screen wording.
public struct LoadingMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let accessibilityText: String?

    public init(id: String, text: String, accessibilityText: String? = nil) {
        self.id = id
        self.text = text
        self.accessibilityText = accessibilityText
    }

    /// What VoiceOver should speak for this message — the explicit override if
    /// provided, otherwise the visible text.
    public var spokenText: String { accessibilityText ?? text }
}

public extension LoadingMessage {
    /// The default playful, tasteful message set. Tasteful and brand-safe; easy
    /// to extend (append more) and localize (each `text` is a catalog key).
    static let playfulDefaults: [LoadingMessage] = [
        LoadingMessage(id: "wrangling-pixels", text: "Still wrangling the pixels…"),
        LoadingMessage(id: "negotiating-server", text: "Negotiating with the server…"),
        LoadingMessage(id: "buttering-popcorn", text: "Buttering the popcorn…"),
        LoadingMessage(id: "dimming-lights", text: "Dimming the lights…"),
        LoadingMessage(id: "untangling-cables", text: "Untangling the cables…"),
        LoadingMessage(id: "summoning-frames", text: "Summoning the frames…"),
        LoadingMessage(id: "warming-projector", text: "Warming up the projector…"),
        LoadingMessage(id: "reticulating-splines", text: "Reticulating splines…"),
        LoadingMessage(id: "warming-tubes", text: "Warming up the tubes…"),
        LoadingMessage(id: "locating-tape", text: "Locating the digital tape…"),
        LoadingMessage(id: "finding-remote", text: "Looking for the remote…"),
        LoadingMessage(id: "almost-there", text: "Almost there, promise…"),
    ]
}

/// Pure, deterministic timing logic for the loading-message experience.
///
/// Given the elapsed time since loading began, it decides whether to show only a
/// plain spinner (the first few seconds) or which playful message to display
/// once loading drags on. Keeping this free of any clock, async, or UI means the
/// threshold and cycling behaviour can be unit-tested exhaustively.
public struct LoadingMessageSequencer: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Show only the normal loading indicator (no playful message yet).
        case spinnerOnly
        /// Show the playful `message` (its position is `index` in the list).
        case message(LoadingMessage, index: Int)
    }

    /// How long to wait, showing only a spinner, before the first playful
    /// message appears. Defaults to a few seconds so quick loads never see them.
    public var initialDelay: TimeInterval
    /// How long each playful message stays before cycling to the next.
    public var cycleInterval: TimeInterval
    /// The messages to cycle through. Empty means "spinner only, forever".
    public var messages: [LoadingMessage]

    public init(
        messages: [LoadingMessage] = LoadingMessage.playfulDefaults,
        initialDelay: TimeInterval = 3.5,
        cycleInterval: TimeInterval = 3.0
    ) {
        self.messages = messages
        self.initialDelay = initialDelay
        self.cycleInterval = cycleInterval
    }

    /// The phase to show for a given elapsed loading time.
    ///
    /// - Before `initialDelay` (or with no messages): `.spinnerOnly`.
    /// - At/after `initialDelay`: the message at `floor((elapsed - initialDelay)
    ///   / cycleInterval)`, wrapping around the list so it cycles indefinitely.
    public func phase(atElapsed elapsed: TimeInterval) -> Phase {
        guard !messages.isEmpty, elapsed >= initialDelay else { return .spinnerOnly }
        let step: Int
        if cycleInterval > 0 {
            // Nudge by a tiny epsilon so an elapsed value landing exactly on a
            // boundary advances deterministically rather than depending on FP.
            step = Int((elapsed - initialDelay + 1e-9) / cycleInterval)
        } else {
            step = 0
        }
        let index = step % messages.count
        return .message(messages[index], index: index)
    }
}

/// Observable driver for the loading-message UI.
///
/// Starts a spinner-only phase, then (if loading is still going after
/// `initialDelay`) begins cycling playful messages on a timer. The actual sleep
/// is injected so tests can drive it deterministically; production uses
/// `Task.sleep`. Cancellation-safe: `stop()` tears down the loop.
@MainActor
@Observable
public final class LoadingMessageModel {
    /// The current phase the view should render.
    public private(set) var phase: LoadingMessageSequencer.Phase = .spinnerOnly

    /// The playful message currently on screen, or `nil` while spinner-only.
    public var currentMessage: LoadingMessage? {
        if case let .message(message, _) = phase { return message }
        return nil
    }

    private var sequencer: LoadingMessageSequencer
    private let shufflesMessages: Bool
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var loop: Task<Void, Never>?

    public init(
        sequencer: LoadingMessageSequencer = LoadingMessageSequencer(),
        shufflesMessages: Bool = true,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.sequencer = sequencer
        self.shufflesMessages = shufflesMessages
        self.sleep = sleep
    }

    /// Begins the spinner → message-cycling sequence. Idempotent: restarts the
    /// loop from the beginning each time.
    public func start() {
        stop()
        var resolved = sequencer
        if shufflesMessages { resolved.messages.shuffle() }
        let seq = resolved
        let sleep = self.sleep
        phase = .spinnerOnly
        // A non-positive cycle interval has no time axis to advance along, so the
        // first message simply holds — never spin a zero-sleep loop that would
        // peg the main actor.
        let cycles = seq.cycleInterval > 0
        loop = Task { @MainActor [weak self] in
            do { try await sleep(seq.initialDelay) } catch { return }
            var step = 0
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = seq.initialDelay + Double(step) * seq.cycleInterval
                self.phase = seq.phase(atElapsed: elapsed)
                guard cycles else { return }
                do { try await sleep(seq.cycleInterval) } catch { return }
                step += 1
            }
        }
    }

    /// Stops cycling and returns to spinner-only.
    public func stop() {
        loop?.cancel()
        loop = nil
        phase = .spinnerOnly
    }
}
