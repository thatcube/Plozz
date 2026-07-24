#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed-footprint overview text shared by heroes and episode columns.
/// Placeholder mode never inserts hidden source text into the view hierarchy.
public struct SpoilerSafeOverviewText: View {
    @Environment(\.themePalette) private var palette
    private let overview: String?
    private let hidesSpoilers: Bool
    private let mode: SpoilerSettings.Mode
    private let lineCount: Int
    private let fontSize: CGFloat
    private let maxWidth: CGFloat?
    /// When `true` the view always reserves `lineCount` lines of height (via a
    /// hidden placeholder) so it keeps a fixed footprint — needed where several
    /// cards must align in a grid (episode columns). The detail hero sets this
    /// `false` so a short synopsis doesn't leave a tall empty gap.
    private let reservesSpace: Bool

    public init(
        overview: String?,
        hidesSpoilers: Bool,
        mode: SpoilerSettings.Mode,
        lineCount: Int = 3,
        fontSize: CGFloat = 22,
        maxWidth: CGFloat? = nil,
        reservesSpace: Bool = true
    ) {
        self.overview = overview
        self.hidesSpoilers = hidesSpoilers
        self.mode = mode
        self.lineCount = lineCount
        self.fontSize = fontSize
        self.maxWidth = maxWidth
        self.reservesSpace = reservesSpace
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if reservesSpace {
                Text(verbatim: layoutReservation)
                    .hidden()
                    .accessibilityHidden(true)
            }

            if hidesSpoilers {
                hiddenOverview
            } else if let overview {
                overviewText(overview)
            }
        }
        .font(.system(size: fontSize))
        .foregroundStyle(.secondary)
        .lineSpacing(2)
        .lineLimit(lineCount)
        .frame(maxWidth: maxWidth, alignment: .topLeading)
        .contentTransition(.opacity)
    }

    /// Renders the overview with inline markdown resolved: tvOS flattens links to
    /// plain label text (no pointer to tap them); iOS/iPadOS renders tappable links.
    @ViewBuilder
    private func overviewText(_ overview: String) -> some View {
        #if os(tvOS)
        Text(verbatim: overview.overviewPlainText)
        #else
        Text(overview.overviewMarkdownWithLegibleLinks(
            textColor: palette.primaryText,
            accent: palette.accent
        ))
        #endif
    }

    private var layoutReservation: String {
        Array(repeating: "M", count: lineCount).joined(separator: "\n")
    }

    @ViewBuilder
    private var hiddenOverview: some View {
        switch mode {
        case .blur:
            if let overview {
                Text(verbatim: overview.overviewPlainText)
                    .blur(radius: 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(EpisodeColumnPresentation.hiddenOverviewLabel)
            } else {
                placeholderOverview
            }
        case .placeholder:
            placeholderOverview
        }
    }

    private var placeholderOverview: some View {
        Text(verbatim: Array(
            repeating: EpisodeColumnPresentation.hiddenOverviewLabel,
            count: lineCount
        ).joined(separator: "\n"))
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EpisodeColumnPresentation.hiddenOverviewLabel)
    }
}
#endif
