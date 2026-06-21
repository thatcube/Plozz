#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A focusable poster/landscape card for a `MediaItem`, with artwork, a watched
/// progress bar, and title/subtitle. The standard building block of Home rows
/// and library grids.
///
/// The `.poster` style keeps tvOS's native `.card` focus parallax. The
/// `.landscape` (medium) style is restyled to match the Twozz medium content
/// card: a 16:9 media well, rounded glass surface, a focus lift with a
/// focused-only drop shadow, and a series-aware title treatment for episodes.
public struct PosterCardView: View {
    public enum Style { case poster, landscape }

    private let item: MediaItem
    private let style: Style
    private let spoilerSettings: SpoilerSettings
    private let action: () -> Void

    @FocusState private var isFocused: Bool

    public init(
        item: MediaItem,
        style: Style = .poster,
        spoilerSettings: SpoilerSettings = .default,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.style = style
        self.spoilerSettings = spoilerSettings
        self.action = action
    }

    private var hideThumbnail: Bool { spoilerSettings.shouldHideThumbnail(for: item) }
    private var hideText: Bool { spoilerSettings.shouldHideText(for: item) }

    private var size: CGSize {
        switch style {
        case .poster:
            return CGSize(width: PlozzTheme.Metrics.posterWidth, height: PlozzTheme.Metrics.posterHeight)
        case .landscape:
            return CGSize(width: PlozzTheme.Metrics.landscapeWidth, height: PlozzTheme.Metrics.landscapeHeight)
        }
    }

    public var body: some View {
        switch style {
        case .poster:
            posterCard
        case .landscape:
            landscapeCard
        }
    }

    // MARK: Poster

    private var posterCard: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                artwork
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.cornerRadius))
                    .overlay(alignment: .bottom) { progressBar(height: 8) }

                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryText)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = subtitleText {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: size.width, alignment: .leading)
            }
        }
        // Native tvOS card styling gives the focus "lift"/parallax for free.
        .buttonStyle(.card)
    }

    // MARK: Landscape (medium) card

    private var landscapeCard: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                artwork
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous))
                    .overlay(alignment: .bottom) { progressBar(height: 8) }

                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(subtitleText ?? " ")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(subtitleText == nil ? 0 : 1)
                }
                .frame(width: size.width, alignment: .leading)
            }
            .padding(PlozzTheme.Metrics.mediumCardInset)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .plozzGlassCard(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, isFocused: isFocused)
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0), radius: 20, y: 10)
        .scaleEffect(isFocused ? PlozzTheme.Metrics.mediumFocusedCardScale : 1)
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    // MARK: Text

    /// Primary line. For episodes this is always the *series* title (never the
    /// episode's own name), which is both more useful in rails like Continue
    /// Watching and inherently spoiler-safe.
    private var primaryText: String {
        if item.kind == .episode, let series = item.parentTitle, !series.isEmpty {
            return series
        }
        if hideText { return spoilerSettings.maskedTitle(for: item) }
        return item.title
    }

    /// Secondary line — e.g. `S1 · E3` for episodes or the production year.
    private var subtitleText: String? { item.subtitle }

    // MARK: Artwork

    /// Ordered list of real-image candidates to try before showing a placeholder.
    private var artworkCandidates: [URL] {
        switch style {
        case .poster:
            return [item.posterURL, item.fallbackArtworkURL].compactMap { $0 }
        case .landscape:
            if item.kind == .episode {
                // An episode's thumbnail is its Primary image; fall back to the
                // series backdrop, then to a neutral placeholder.
                return [item.posterURL, item.backdropURL, item.fallbackArtworkURL].compactMap { $0 }
            }
            return [item.backdropURL, item.posterURL, item.fallbackArtworkURL].compactMap { $0 }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if hideThumbnail {
            switch spoilerSettings.mode {
            case .blur:
                realArtwork.blur(radius: 28)
            case .placeholder:
                placeholderArtwork
            }
        } else {
            realArtwork
        }
    }

    private var realArtwork: some View {
        FallbackAsyncImage(urls: artworkCandidates) {
            neutralPlaceholder
        }
    }

    /// Spoiler-safe art for `.placeholder` mode: only ever the series fallback
    /// artwork (never the real episode frame), then a neutral placeholder.
    private var placeholderArtwork: some View {
        FallbackAsyncImage(urls: [item.fallbackArtworkURL].compactMap { $0 }) {
            neutralPlaceholder
        }
    }

    /// Neutral, theme-agnostic placeholder showing the (series) title. Carries no
    /// episode-number text — the `S· · E·` subtitle already conveys that.
    private var neutralPlaceholder: some View {
        ZStack {
            Color.primary.opacity(0.08)
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(primaryText)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Progress

    @ViewBuilder
    private func progressBar(height: CGFloat) -> some View {
        if let percentage = item.playedPercentage, percentage > 0.01, percentage < 0.99 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.4))
                    Rectangle()
                        .fill(.tint)
                        .frame(width: geo.size.width * percentage)
                }
            }
            .frame(height: height)
        }
    }
}

#endif
