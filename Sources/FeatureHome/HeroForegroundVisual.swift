#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreModels
import CoreUI

/// The concrete inputs for one rasterized hero **description column** — logo/
/// title, metadata line and overview — captured as a plain value so the render is
/// deterministic and matches its ``HeroForegroundFingerprint`` exactly. Nothing
/// here loads asynchronously: the logo is a pre-resolved `UIImage` (or `nil` → the
/// styled text title), so a one-shot `ImageRenderer` captures the finished pixels.
struct HeroForegroundContent {
    /// Title text as drawn (already spoiler-masked when masking applies).
    let title: String
    /// Overview text, or `nil` when the slide shows none (spoiler-hidden).
    let overview: String?
    /// The dotted metadata components (year · runtime · genres …), pre-joined by
    /// the caller into the same string the live line renders.
    let metadata: String
    /// The rating badge chip to draw, or `nil`.
    let ratingBadge: MediaBadge?
    /// The pre-resolved, background-stripped logo image, or `nil` → text title.
    let logoImage: UIImage?
    /// The measured action-row width the column caps its logo/title/overview to
    /// (matching the live path). `0` → the component defaults.
    let contentWidth: CGFloat
}

/// A **visual-only**, non-focusable rendition of the hero's description column,
/// used exclusively by the experimental foreground rasterizer
/// (`PLZHERO_RASTER_FOREGROUND`). It mirrors the live column in `HomeHeroView`
/// (`HeroLogoArtwork`/text title → metadata line → overview, 12pt spacing, the
/// same fonts, caps and legibility shadow) so a baked snapshot reads the same as
/// the live foreground it replaces.
///
/// It deliberately does **not** include the action pills, the focus overlay or the
/// paging dots — those stay live in `HomeHeroView` so action feedback, focus and
/// accessibility are never stale. It carries no interactivity and is marked
/// accessibility-hidden by the caller (the live overlay owns accessibility).
struct HeroForegroundVisual: View {
    let content: HeroForegroundContent
    let colorScheme: ColorScheme

    private var logoCap: CGFloat { content.contentWidth > 0 ? content.contentWidth : 620 }
    private var titleCap: CGFloat { content.contentWidth > 0 ? content.contentWidth : 1200 }
    private var overviewCap: CGFloat { content.contentWidth > 0 ? content.contentWidth : 960 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            logoOrTitle

            metadataLine
                .modifier(HeroTextLegibilityShadow(colorScheme: colorScheme))

            if let overview = content.overview {
                Text(overview)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: overviewCap, alignment: .topLeading)
                    .modifier(HeroTextLegibilityShadow(colorScheme: colorScheme))
            }
        }
        .environment(\.colorScheme, colorScheme)
    }

    @ViewBuilder
    private var logoOrTitle: some View {
        if let logo = content.logoImage {
            // Fit (never crop) inside the same maxWidth × maxHeight box the live
            // `HeroLogoArtwork` uses, leading-aligned.
            Image(uiImage: logo)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: logoCap, maxHeight: 200, alignment: .leading)
        } else {
            Text(content.title)
                .font(.system(size: 64, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: titleCap, alignment: .leading)
        }
    }

    @ViewBuilder
    private var metadataLine: some View {
        if content.ratingBadge != nil || !content.metadata.isEmpty {
            HStack(alignment: .center, spacing: 16) {
                if let badge = content.ratingBadge {
                    MediaBadgeChip(badge: badge)
                }
                if !content.metadata.isEmpty {
                    Text(content.metadata)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
#endif
