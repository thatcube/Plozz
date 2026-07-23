#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The shared watch-state chip shown over an episode thumbnail on both iOS and
/// tvOS detail pages. It renders the same three states everywhere so the
/// resume affordance is consistent across platforms:
///  - **in progress** → `▶ [progress bar] 12m` (reusing ``ResumeProgressCapsule``,
///    the exact bar used inside the hero Play/Resume button),
///  - **watched** → a checkmark,
///  - **not started** → the plain runtime (e.g. `52m`).
///
/// The `showsRuntimeWhenIdle` / `showsWatched` flags let a platform opt out of
/// the idle/watched forms: tvOS keeps its own corner watched badge and shows the
/// chip only while an episode is in progress, whereas iOS uses the chip for all
/// three states. When there's nothing to show the view renders empty (no chip).
public struct EpisodeWatchStatePill: View {
    private let item: MediaItem
    private let showsRuntimeWhenIdle: Bool
    private let showsWatched: Bool
    private let showsBackground: Bool
    private let barWidth: CGFloat
    private let barHeight: CGFloat
    private let playGlyphHeight: CGFloat?

    public init(
        item: MediaItem,
        showsRuntimeWhenIdle: Bool = true,
        showsWatched: Bool = true,
        showsBackground: Bool = true,
        barWidth: CGFloat = 54,
        barHeight: CGFloat = 5,
        playGlyphHeight: CGFloat? = nil
    ) {
        self.item = item
        self.showsRuntimeWhenIdle = showsRuntimeWhenIdle
        self.showsWatched = showsWatched
        self.showsBackground = showsBackground
        self.barWidth = barWidth
        self.barHeight = barHeight
        self.playGlyphHeight = playGlyphHeight
    }

    private enum State {
        case watched
        case inProgress(fraction: Double, remaining: String)
        case runtime(String)
    }

    private var state: State? {
        if showsWatched, item.isPlayed {
            return .watched
        }
        if let fraction = item.resumeProgressFraction,
           let remaining = item.resumeRemainingText {
            return .inProgress(fraction: fraction, remaining: remaining)
        }
        if showsRuntimeWhenIdle, let runtime = item.runtime?.runtimeBadgeText {
            return .runtime(runtime)
        }
        return nil
    }

    public var body: some View {
        if let state {
            content(for: state)
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                .modifier(
                    PillBackground(enabled: showsBackground)
                )
        }
    }

    @ViewBuilder
    private func content(for state: State) -> some View {
        switch state {
        case .watched:
            Image(systemName: "checkmark")
                .fontWeight(.bold)
                .accessibilityLabel("Watched")
        case let .inProgress(fraction, remaining):
            HStack(spacing: 8) {
                playGlyph
                ResumeProgressCapsule(
                    progress: fraction,
                    onLight: false,
                    width: barWidth,
                    height: barHeight
                )
                Text(remaining)
            }
            .accessibilityLabel("\(remaining) left")
        case let .runtime(text):
            Text(text)
        }
    }

    @ViewBuilder
    private var playGlyph: some View {
        if let playGlyphHeight {
            Image(systemName: "play.fill")
                .resizable()
                .scaledToFit()
                .frame(height: playGlyphHeight)
        } else {
            Image(systemName: "play.fill")
        }
    }
}

/// Wraps pill content in the optional dark capsule. When disabled the pill has
/// no background at all — legibility comes from the host image's dark scrim plus
/// the text shadow — matching the "no solid background behind text" rule.
private struct PillBackground: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.5), in: Capsule())
        } else {
            content
        }
    }
}

/// The shared resume/runtime chip overlay drawn on a landscape thumbnail — used
/// identically by episode cards and immediate-play (Continue Watching / landscape
/// library) cards so both read the same. A soft bottom-leading legibility scrim
/// with the white play/progress/time chip (in progress) or plain runtime (not
/// started), no solid capsule. Renders nothing when the item has no runtime to
/// show. Callers gate it on artwork being visible (not blurred/hidden).
public struct ResumeChipOverlay: View {
    private let item: MediaItem

    public init(item: MediaItem) {
        self.item = item
    }

    public var body: some View {
        if item.cardRuntimeText != nil {
            GeometryReader { proxy in
                RadialGradient(
                    colors: [.black.opacity(0.55), .clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.8
                )
            }
            .allowsHitTesting(false)
            .overlay(alignment: .bottomLeading) {
                EpisodeWatchStatePill(
                    item: item,
                    showsRuntimeWhenIdle: true,
                    showsWatched: false,
                    showsBackground: false,
                    barWidth: 80,
                    barHeight: 6
                )
                .font(.system(size: 24, weight: .semibold))
                .padding(18)
            }
        }
    }
}
#endif
