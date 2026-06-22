#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The lower-detail metadata block: cast row, plus a studios/tags information
/// strip. Shown beneath the hero on movie and series detail pages so the rich
/// metadata Jellyfin already holds (and the web client shows) is finally
/// surfaced on tvOS — most valuable for anime, where voice cast, studios and
/// tags are the defining metadata.
struct DetailExtrasView: View {
    let item: MediaItem

    private var hasContent: Bool {
        !item.cast.isEmpty || !item.studios.isEmpty || !item.tags.isEmpty
    }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 28) {
                if !item.cast.isEmpty {
                    CastRowView(people: item.cast)
                }
                if !item.studios.isEmpty {
                    InfoChipsRow(title: "Studios", values: item.studios)
                }
                if !item.tags.isEmpty {
                    InfoChipsRow(title: "Tags", values: item.tags)
                }
            }
        }
    }
}

/// A labelled, wrapping strip of pill chips (e.g. studios or tags).
private struct InfoChipsRow: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 32, weight: .bold))
            FlowLayout(spacing: 12, lineSpacing: 12) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 18)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.10))
                        )
                }
            }
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
    }
}

/// A minimal flow (wrapping) layout so chips wrap onto new lines instead of
/// overflowing the screen width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        let height = rows.reduce(CGFloat(0)) { acc, row in
            let rowHeight = row.map(\.height).max() ?? 0
            return acc + rowHeight + lineSpacing
        } - (rows.isEmpty ? 0 : lineSpacing)
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#endif
