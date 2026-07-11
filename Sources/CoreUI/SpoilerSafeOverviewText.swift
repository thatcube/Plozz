#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed-footprint overview text shared by heroes and episode columns.
/// Placeholder mode never inserts hidden source text into the view hierarchy.
public struct SpoilerSafeOverviewText: View {
    private let overview: String?
    private let hidesSpoilers: Bool
    private let mode: SpoilerSettings.Mode
    private let lineCount: Int
    private let fontSize: CGFloat
    private let maxWidth: CGFloat?

    public init(
        overview: String?,
        hidesSpoilers: Bool,
        mode: SpoilerSettings.Mode,
        lineCount: Int = 3,
        fontSize: CGFloat = 22,
        maxWidth: CGFloat? = nil
    ) {
        self.overview = overview
        self.hidesSpoilers = hidesSpoilers
        self.mode = mode
        self.lineCount = lineCount
        self.fontSize = fontSize
        self.maxWidth = maxWidth
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Text(verbatim: layoutReservation)
                .hidden()
                .accessibilityHidden(true)

            if hidesSpoilers {
                hiddenOverview
            } else if let overview {
                Text(overview)
            }
        }
        .font(.system(size: fontSize))
        .foregroundStyle(.secondary)
        .lineSpacing(2)
        .lineLimit(lineCount)
        .frame(maxWidth: maxWidth, alignment: .topLeading)
        .contentTransition(.opacity)
    }

    private var layoutReservation: String {
        Array(repeating: "M", count: lineCount).joined(separator: "\n")
    }

    @ViewBuilder
    private var hiddenOverview: some View {
        switch mode {
        case .blur:
            if let overview {
                Text(overview)
                    .blur(radius: 12)
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
