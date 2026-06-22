#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The top "hero" section of a detail page: a full-bleed backdrop with the
/// item's title, subtitle, ratings, overview, and an optional Play button.
///
/// It is intentionally stateless and driven entirely by `item`, so a parent can
/// swap which item it shows (series → focused season → focused episode) and the
/// whole hero animates to reflect the newly focused context.
struct DetailHeroView: View {
    let item: MediaItem
    let spoilerSettings: SpoilerSettings
    /// Title for the Play/Resume button, or `nil` to omit the button entirely
    /// (e.g. a season with no resolved episodes yet).
    let playTitle: String?
    let onPlay: (() -> Void)?

    @Environment(\.themePalette) private var palette

    var body: some View {
        let hideText = spoilerSettings.shouldHideText(for: item)
        let hideThumbnail = spoilerSettings.shouldHideThumbnail(for: item)
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: item.backdropURL ?? item.posterURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.tertiary)
            }
            .frame(height: 720)
            .frame(maxWidth: .infinity)
            .clipped()
            .blur(radius: hideThumbnail && spoilerSettings.mode == .blur ? 40 : 0)
            .overlay(
                // Fade the backdrop down into the app's own background colour so
                // the hero reads as full-bleed and dissolves seamlessly into the
                // page right where the season tabs begin — no hard seam.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: palette.backgroundBase.opacity(0.55), location: 0.6),
                        .init(color: palette.backgroundBase, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Break out of the tvOS overscan safe area so the backdrop spans the
            // full screen width edge to edge.
            .ignoresSafeArea(edges: .horizontal)

            VStack(alignment: .leading, spacing: 16) {
                Text(hideText ? spoilerSettings.maskedTitle(for: item) : item.title)
                    .font(.system(size: 64, weight: .bold))
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.title3).foregroundStyle(.secondary)
                }
                if !item.ratings.isEmpty {
                    RatingsBadgeRow(ratings: item.ratings)
                }
                if hideText {
                    Label("Overview hidden to avoid spoilers", systemImage: "eye.slash.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                } else if let overview = item.overview {
                    Text(overview)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                if let playTitle, let onPlay {
                    Button(action: onPlay) {
                        Label(playTitle, systemImage: "play.fill")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
            }
            .padding(PlozzTheme.Metrics.screenPadding)
        }
        // Cross-fade the hero text as the focused context changes, while the
        // backdrop swaps underneath it.
        .animation(.easeInOut(duration: 0.2), value: item.id)
    }
}

#endif
