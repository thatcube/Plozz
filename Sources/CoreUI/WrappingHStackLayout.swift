#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct WrappingHStackLayout: Layout {
    public enum RowAlignment: Sendable {
        case leading
        case center
        case trailing
    }

    public var alignment: RowAlignment
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(
        alignment: RowAlignment = .leading,
        spacing: CGFloat = 12,
        lineSpacing: CGFloat = 12
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let naturalWidth = subviews.indices.reduce(CGFloat.zero) {
            partial, index in
            partial
                + subviews[index].sizeThatFits(.unspecified).width
                + (index == subviews.startIndex ? 0 : spacing)
        }
        let maxWidth = finiteWidth(
            from: proposal.width,
            naturalWidth: naturalWidth
        )
        let rows = makeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.enumerated().reduce(CGFloat.zero) { result, entry in
            result + entry.element.height
                + (entry.offset == rows.count - 1 ? 0 : lineSpacing)
        }
        return CGSize(width: maxWidth, height: height)
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let rows = makeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX + horizontalOffset(
                rowWidth: row.width,
                availableWidth: bounds.width
            )
            for index in row.startIndex..<row.endIndex {
                let size = row.sizes[index - row.startIndex]
                subviews[index].place(
                    at: CGPoint(
                        x: x,
                        y: y + (row.height - size.height) / 2
                    ),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        let startIndex: Int
        let endIndex: Int
        let sizes: [CGSize]
        let width: CGFloat
        let height: CGFloat
    }

    private func makeRows(
        maxWidth: CGFloat,
        subviews: Subviews
    ) -> [Row] {
        var rows: [Row] = []
        var startIndex = 0
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let candidateWidth = sizes.isEmpty
                ? size.width
                : width + spacing + size.width

            if candidateWidth > maxWidth, !sizes.isEmpty {
                rows.append(
                    Row(
                        startIndex: startIndex,
                        endIndex: index,
                        sizes: sizes,
                        width: width,
                        height: height
                    )
                )
                startIndex = index
                sizes = []
                width = 0
                height = 0
            }

            width = sizes.isEmpty ? size.width : width + spacing + size.width
            height = max(height, size.height)
            sizes.append(size)
        }

        if !sizes.isEmpty {
            rows.append(
                Row(
                    startIndex: startIndex,
                    endIndex: subviews.count,
                    sizes: sizes,
                    width: width,
                    height: height
                )
            )
        }
        return rows
    }

    private func horizontalOffset(
        rowWidth: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        switch alignment {
        case .leading:
            return 0
        case .center:
            return max(0, (availableWidth - rowWidth) / 2)
        case .trailing:
            return max(0, availableWidth - rowWidth)
        }
    }

    private func finiteWidth(
        from proposedWidth: CGFloat?,
        naturalWidth: CGFloat
    ) -> CGFloat {
        if let proposedWidth, proposedWidth.isFinite, proposedWidth > 0 {
            return proposedWidth
        }
        return naturalWidth
    }
}
#endif
