#if canImport(SwiftUI)
import Foundation
import Observation
import SwiftUI

public enum TransientStatusPlacement: Hashable, Sendable {
    case root
    case musicTransport
}

public struct TransientStatusMessage: Equatable, Sendable {
    public let icon: String
    public let text: LocalizedStringResource
    public let placement: TransientStatusPlacement

    public init(
        icon: String,
        text: LocalizedStringResource,
        placement: TransientStatusPlacement = .root
    ) {
        self.icon = icon
        self.text = text
        self.placement = placement
    }
}

@MainActor
@Observable
public final class TransientStatusPresenter {
    public typealias Sleeper = @Sendable (Duration) async -> Void
    public typealias Announcement =
        @MainActor @Sendable (LocalizedStringResource) -> Void

    public static let defaultDisplayDuration: Duration = .milliseconds(1_600)
    public static let presentationAnimationDuration: TimeInterval = 0.2
    public static let dismissalAnimationDuration: TimeInterval = 0.3

    public private(set) var message: TransientStatusMessage?

    @ObservationIgnored private let displayDuration: Duration
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private let announcement: Announcement
    @ObservationIgnored private var dismissalTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    public init(
        displayDuration: Duration = defaultDisplayDuration,
        sleeper: @escaping Sleeper = { duration in
            try? await Task.sleep(for: duration)
        },
        announcement: @escaping Announcement = { text in
            #if os(tvOS) || os(iOS)
            AccessibilityNotification.Announcement(
                String(localized: text)
            ).post()
            #endif
        }
    ) {
        self.displayDuration = displayDuration
        self.sleeper = sleeper
        self.announcement = announcement
    }

    deinit {
        dismissalTask?.cancel()
    }

    public func present(
        icon: String,
        text: LocalizedStringResource,
        placement: TransientStatusPlacement = .root
    ) {
        generation &+= 1
        let expectedGeneration = generation
        dismissalTask?.cancel()
        withAnimation(.easeInOut(
            duration: Self.presentationAnimationDuration
        )) {
            message = TransientStatusMessage(
                icon: icon,
                text: text,
                placement: placement
            )
        }
        announcement(text)

        let displayDuration = self.displayDuration
        let sleeper = self.sleeper
        dismissalTask = Task { [weak self] in
            await sleeper(displayDuration)
            guard !Task.isCancelled else { return }
            await self?.dismiss(expectedGeneration: expectedGeneration)
        }
    }

    public func dismiss() {
        generation &+= 1
        dismissalTask?.cancel()
        dismissalTask = nil
        withAnimation(.easeInOut(
            duration: Self.dismissalAnimationDuration
        )) {
            message = nil
        }
    }

    private func dismiss(expectedGeneration: UInt64) {
        guard expectedGeneration == generation else { return }
        dismissalTask = nil
        withAnimation(.easeInOut(
            duration: Self.dismissalAnimationDuration
        )) {
            message = nil
        }
    }
}

public struct TransientStatusView: View {
    private let presenter: TransientStatusPresenter
    private let placement: TransientStatusPlacement
    private let isLightSurface: Bool

    public init(
        presenter: TransientStatusPresenter,
        placement: TransientStatusPlacement = .root,
        isLightSurface: Bool = false
    ) {
        self.presenter = presenter
        self.placement = placement
        self.isLightSurface = isLightSurface
    }

    public var body: some View {
        Group {
            if let message = presenter.message,
               message.placement == placement {
                HStack(spacing: 10) {
                    Image(systemName: message.icon)
                    Text(message.text)
                }
                .font(messageFont)
                .foregroundStyle(.primary)
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        .white.opacity(isLightSurface ? 0.15 : 0.12),
                        lineWidth: 1
                    )
                )
                .shadow(
                    color: .black.opacity(isLightSurface ? 0.12 : 0.4),
                    radius: 12,
                    y: 4
                )
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var messageFont: Font {
        #if os(iOS)
        placement == .root
            ? .headline.weight(.semibold)
            : .system(size: 22, weight: .semibold)
        #else
        .system(size: 22, weight: .semibold)
        #endif
    }
}

private struct TransientStatusPresenterKey: EnvironmentKey {
    static let defaultValue: TransientStatusPresenter? = nil
}

public extension EnvironmentValues {
    var transientStatusPresenter: TransientStatusPresenter? {
        get { self[TransientStatusPresenterKey.self] }
        set { self[TransientStatusPresenterKey.self] = newValue }
    }
}

public extension View {
    func transientStatusPresenter(
        _ presenter: TransientStatusPresenter?
    ) -> some View {
        environment(\.transientStatusPresenter, presenter)
    }

    /// Overlay-only host: no layout participation, focus target, or hit testing.
    func transientStatusOverlay(
        presenter: TransientStatusPresenter,
        placement: TransientStatusPlacement = .root,
        alignment: Alignment = .bottom,
        bottomPadding: CGFloat = 48,
        isLightSurface: Bool = false
    ) -> some View {
        overlay(alignment: alignment) {
            TransientStatusView(
                presenter: presenter,
                placement: placement,
                isLightSurface: isLightSurface
            )
            .padding(.bottom, bottomPadding)
        }
        .transientStatusPresenter(presenter)
    }
}
#endif
