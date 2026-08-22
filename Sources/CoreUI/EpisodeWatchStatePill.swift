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
    private let detailText: String?
    private let showsPlayGlyphWhenIdle: Bool

    @Environment(\.plozzChromeIsFocused) private var isFocused

    /// - Parameters:
    ///   - detailText: a short qualifier shown immediately before the duration
    ///     (e.g. `S4 E1`), joined with `·`. Continue Watching uses it so a card
    ///     whose artwork is the *show* still says which episode you are on.
    ///   - showsPlayGlyphWhenIdle: draws the play glyph on the not-started form
    ///     too. An unstarted episode has no progress to draw, so the bar is
    ///     omitted and the glyph alone carries "this resumes".
    public init(
        item: MediaItem,
        showsRuntimeWhenIdle: Bool = true,
        showsWatched: Bool = true,
        showsBackground: Bool = true,
        barWidth: CGFloat = 54,
        barHeight: CGFloat = 5,
        playGlyphHeight: CGFloat? = nil,
        detailText: String? = nil,
        showsPlayGlyphWhenIdle: Bool = false
    ) {
        self.item = item
        self.showsRuntimeWhenIdle = showsRuntimeWhenIdle
        self.showsWatched = showsWatched
        self.showsBackground = showsBackground
        self.barWidth = barWidth
        self.barHeight = barHeight
        self.playGlyphHeight = playGlyphHeight
        self.detailText = detailText
        self.showsPlayGlyphWhenIdle = showsPlayGlyphWhenIdle
    }

    private enum State {
        case watched
        /// `remaining` is optional: an item can be resumable without a known
        /// runtime (some providers omit it, and a series-level entry has none), and
        /// the glyph + bar are the useful part. Requiring the label meant those
        /// items lost the whole chip and fell back to the plain full-width bar, so
        /// Continue Watching showed two different treatments side by side.
        case inProgress(fraction: Double, remaining: String?)
        /// Not started. The duration is optional so a provider that reports no
        /// runtime can still show a `detailText`-only chip — without it a Continue
        /// Watching card, which has no caption to fall back on, would say nothing
        /// at all about which episode it is.
        case runtime(String?)
    }

    private var state: State? {
        if showsWatched, item.isPlayed {
            return .watched
        }
        if let fraction = item.resumeProgressFraction {
            return .inProgress(fraction: fraction, remaining: item.resumeRemainingText)
        }
        if showsRuntimeWhenIdle, let runtime = item.runtime?.runtimeBadgeText {
            return .runtime(runtime)
        }
        if showsPlayGlyphWhenIdle, detailText?.isEmpty == false {
            return .runtime(nil)
        }
        return nil
    }

    public var body: some View {
        if let state {
            content(for: state)
                .foregroundStyle(PlozzMediaChrome.foreground(isFocused: isFocused))
                .lineLimit(1)
                // Flat. Legibility is the scrim's job (`MediaArtworkChromeScrim`);
                // a shadow here made the chip read as a sticker on the artwork
                // rather than part of it.
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
                if let trailing = joined(remaining) { Text(verbatim: trailing) }
            }
            .accessibilityLabel(
                remaining.map { Text("\($0) left") }
                    ?? Text(
                        "Partly watched",
                        comment: """
                            Accessibility label for the progress chip on a partly \
                            watched card, used when the remaining time is unknown. \
                            Describes watch state, not a command.
                            """
                    )
            )
        case let .runtime(text):
            // Nothing has been watched, so there is no progress to draw. Omitting
            // the bar rather than drawing an empty one keeps the chip honest — an
            // unstarted episode showing a 0% bar reads as a stalled download.
            if let label = joined(text) {
                if showsPlayGlyphWhenIdle {
                    HStack(spacing: 8) {
                        playGlyph
                        Text(verbatim: label)
                    }
                } else {
                    Text(verbatim: label)
                }
            }
        }
    }

    /// `detailText` and a duration as one dotted run — "S4 E1 · 22m" — dropping
    /// either side when it is absent.
    private func joined(_ duration: String?) -> String? {  // l10n:content — joins a hand-built S/E designation with a formatted duration
        let parts = [detailText, duration].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
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
    private let downloadState: MediaDownloadBadgeState?
    private let showsMenu: Bool
    private let detailText: String?
    private let showsPlayGlyphWhenIdle: Bool

    @Environment(\.plozzMetrics) private var metrics

    /// - Parameters:
    ///   - downloadState: optional trailing download affordance. `nil` renders the
    ///     chip as before, so surfaces with no download concept are unaffected.
    ///   - showsMenu: draws the visible "…" actions menu. A press-and-hold menu is
    ///     discoverable on tvOS (cards focus before they're chosen) but hidden on a
    ///     touch card, so touch surfaces opt in.
    ///   - detailText: a short qualifier shown before the duration (e.g. `S4 E1`).
    ///   - showsPlayGlyphWhenIdle: give the not-started form a play glyph and no
    ///     progress bar.
    public init(
        item: MediaItem,
        downloadState: MediaDownloadBadgeState? = nil,
        showsMenu: Bool = false,
        detailText: String? = nil,
        showsPlayGlyphWhenIdle: Bool = false
    ) {
        self.item = item
        self.downloadState = downloadState
        self.showsMenu = showsMenu
        self.detailText = detailText
        self.showsPlayGlyphWhenIdle = showsPlayGlyphWhenIdle
    }

    public var body: some View {
        // The scrim exists for the chrome's legibility, so with nothing to show
        // there's nothing to darken — a card with no runtime stays clean.
        if hasBottomChrome || showsMenu {
            Color.clear
                .overlay {
                    MediaArtworkChromeScrim(top: showsMenu, bottom: hasBottomChrome)
                }
                .overlay(alignment: .topLeading) {
                    if showsMenu {
                        MediaItemEllipsisMenu(item: item)
                    }
                }
            .allowsHitTesting(showsMenu)
            .overlay(alignment: .bottom) {
                // The bar is sized against the CARD, not a constant. At its full
                // 80pt it fits a landscape thumbnail comfortably, but a poster in a
                // dense grid can be ~86pt wide, where a fixed bar plus the time
                // text would overflow the card. Reading the host's width keeps the
                // wide cards pixel-identical and only shrinks where it must.
                GeometryReader { geometry in
                    let barWidth = min(
                        metrics.resumeChipBarWidth,
                        max(20, geometry.size.width * 0.42)
                    )
                    HStack(alignment: .center, spacing: metrics.resumeChipInset * 0.5) {
                        if item.cardRuntimeText != nil
                            || item.resumeProgressFraction != nil
                            || (showsPlayGlyphWhenIdle && detailText?.isEmpty == false) {
                            EpisodeWatchStatePill(
                                item: item,
                                showsRuntimeWhenIdle: true,
                                showsWatched: false,
                                showsBackground: false,
                                barWidth: barWidth,
                                barHeight: metrics.resumeChipBarHeight,
                                detailText: detailText,
                                showsPlayGlyphWhenIdle: showsPlayGlyphWhenIdle
                            )
                            .font(.system(size: metrics.resumeChipFontSize, weight: .semibold))
                            // Last-resort guard for a very narrow card with a long
                            // remaining string ("1h 12m"): shrink rather than clip.
                            .minimumScaleFactor(0.75)
                        }
                        // Keeps the download badge pinned trailing whether or not
                        // the pill is present, so it never drifts to the leading edge.
                        Spacer(minLength: metrics.resumeChipInset * 0.5)
                        if let downloadState {
                            MediaDownloadBadge(
                                state: downloadState,
                                size: metrics.resumeChipAccessorySize
                            )
                        }
                    }
                    .padding(metrics.resumeChipInset)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .bottom
                    )
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Anything to draw along the bottom edge. Resume progress counts even with no
    /// runtime text — see `EpisodeWatchStatePill.State.inProgress`.
    private var hasBottomChrome: Bool {
        item.cardRuntimeText != nil
            || item.resumeProgressFraction != nil
            || downloadState != nil
            // A designation alone is worth a chip: on a series-artwork card it is
            // the only thing naming the episode.
            || (showsPlayGlyphWhenIdle && detailText?.isEmpty == false)
    }

}
#endif
