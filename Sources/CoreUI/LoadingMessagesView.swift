#if canImport(SwiftUI)
import SwiftUI

/// Reusable loading indicator that starts as a plain spinner and, only if
/// loading drags on past a threshold, begins cycling tasteful, on-brand messages
/// that animate in and out — so the user knows we're genuinely still working.
///
/// Accessibility:
///  * Respects **Reduce Motion** — cross-fades instead of sliding when set.
///  * Announces each new message **politely** to VoiceOver (non-interrupting).
///
/// Drop it in anywhere a load can take a moment (detail screens, Home, playback
/// prep). It owns its own `LoadingMessageModel`, so callers just place it.
public struct LoadingMessagesView: View {
    @State private var model: LoadingMessageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spinnerScale: CGFloat
    private let spinnerTint: Color?
    private let messageColor: Color

    /// - Parameters:
    ///   - messages: the message set to cycle (defaults to the playful set).
    ///   - initialDelay: spinner-only grace period before messages begin.
    ///   - cycleInterval: how long each message stays before the next.
    ///   - spinnerScale: scale applied to the `ProgressView`.
    ///   - spinnerTint: optional spinner tint (e.g. white over a dark player).
    ///   - messageColor: message text colour.
    public init(
        messages: [LoadingMessage] = LoadingMessage.playfulDefaults,
        initialDelay: TimeInterval = 6.0,
        cycleInterval: TimeInterval = 5.5,
        spinnerScale: CGFloat = 1.5,
        spinnerTint: Color? = nil,
        messageColor: Color = .secondary
    ) {
        _model = State(initialValue: LoadingMessageModel(
            sequencer: LoadingMessageSequencer(
                messages: messages,
                initialDelay: initialDelay,
                cycleInterval: cycleInterval
            )
        ))
        self.spinnerScale = spinnerScale
        self.spinnerTint = spinnerTint
        self.messageColor = messageColor
    }

    public var body: some View {
        VStack(spacing: 28) {
            ProgressView()
                .scaleEffect(spinnerScale)
                .tint(spinnerTint)

            // Reserve a stable slot so the spinner doesn't jump when a message
            // appears; the message cross-fades within it.
            ZStack {
                if let message = model.currentMessage {
                    Text(LocalizedStringKey(message.text))
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(messageColor)
                        .frame(maxWidth: 900)
                        .id(message.id)
                        .transition(messageTransition)
                        .accessibilityLabel(Text(message.spokenText))
                }
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(messageAnimation, value: model.currentMessage)
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.currentMessage) { _, message in
            guard let message else { return }
            announce(message)
        }
    }

    /// A calm, ambient cross-fade with a gentle scale — deliberately NOT a
    /// directional slide, which reads like a toast/error banner. Reduce Motion
    /// gets a plain opacity fade.
    private var messageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.94))
    }

    private var messageAnimation: Animation {
        // Slow, soft ease — no spring bounce — so a new message settles in gently
        // rather than snapping like an alert.
        .easeInOut(duration: reduceMotion ? 0.3 : 0.6)
    }

    /// Politely announce the new message to VoiceOver without interrupting.
    private func announce(_ message: LoadingMessage) {
        #if os(tvOS) || os(iOS)
        AccessibilityNotification.Announcement(message.spokenText).post()
        #endif
    }
}
#endif
