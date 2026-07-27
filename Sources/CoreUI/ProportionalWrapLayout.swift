#if canImport(SwiftUI)
import SwiftUI

/// Lays views out in equal-width cells that keep a fixed share of the container
/// until there is no room for it, then wrap and fill whatever is left.
///
/// The ratings row wants both halves of that. One rating stretched across the
/// full width of the Ratings column read as a mistake, a lone tile pretending to
/// be a table; sizing every tile to a quarter makes one rating look like one of
/// four, which is what it is. But a fixed quarter is wrong the moment the column
/// is narrow, because the tiles would shrink below legibility rather than use the
/// space, so the share is a preference and not a rule: below `minimumCellWidth`
/// the layout drops to as many columns as actually fit and divides the width
/// evenly between them.
///
/// A `LazyVGrid` cannot express this. Adaptive columns stretch to fill the row,
/// which is the behaviour being fixed, and a fixed column count cannot fall back
/// when the container is too narrow for it.
public struct ProportionalWrapLayout: Layout {
    /// How many cells make up a full row at full width. Every cell is 1/this of
    /// the container, so a partial row occupies a proportional share of it.
    public var preferredColumns: Int
    /// Below this, the preferred share is abandoned in favour of fewer columns.
    public var minimumCellWidth: CGFloat
    public var spacing: CGFloat
    /// A floor on the layout's own height, so it can be made to match a sibling
    /// column without depending on the container stretching it. Rows divide any
    /// surplus between them, so the tiles grow rather than leaving a gap.
    ///
    /// This is deliberately an input rather than a `.frame(maxHeight: .infinity)`
    /// on the outside: a `Grid` only stretches a cell it has decided is flexible,
    /// which is exactly the behaviour that could not be made to hold on tvOS.
    /// Reporting the target as the layout's *natural* height removes the question.
    public var minimumHeight: CGFloat

    public init(
        preferredColumns: Int,
        minimumCellWidth: CGFloat,
        spacing: CGFloat,
        minimumHeight: CGFloat = 0
    ) {
        self.preferredColumns = max(1, preferredColumns)
        self.minimumCellWidth = max(1, minimumCellWidth)
        self.spacing = max(0, spacing)
        self.minimumHeight = max(0, minimumHeight)
    }

    /// Columns that fit, and the width each one gets.
    private func metrics(forWidth width: CGFloat) -> (columns: Int, cellWidth: CGFloat) {
        guard width > 0 else { return (1, minimumCellWidth) }
        let preferredWidth = (width - spacing * CGFloat(preferredColumns - 1))
            / CGFloat(preferredColumns)
        if preferredWidth >= minimumCellWidth {
            return (preferredColumns, preferredWidth)
        }
        // Too narrow for the preferred share: fit what we can and divide evenly,
        // so the row fills the container instead of leaving a ragged gap.
        let fitting = max(1, Int((width + spacing) / (minimumCellWidth + spacing)))
        let columns = min(preferredColumns, fitting)
        let cellWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return (columns, cellWidth)
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? minimumCellWidth * CGFloat(preferredColumns)
        let (columns, cellWidth) = metrics(forWidth: width)
        let rows = Int(ceil(Double(subviews.count) / Double(columns)))
        // Uniform row height: tiles in a row should agree, and the tallest is the
        // only height that fits all of them.
        let rowHeight = subviews
            .map { $0.sizeThatFits(.init(width: cellWidth, height: nil)).height }
            .max() ?? 0
        let natural = rowHeight * CGFloat(rows) + spacing * CGFloat(max(0, rows - 1))
        // The height is ours to report, and it ignores the proposal entirely: the
        // caller measures this value to size the column beside it, so growing into
        // whatever was proposed would feed that measurement back into itself.
        return CGSize(width: width, height: max(natural, minimumHeight))
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard !subviews.isEmpty else { return }
        let (columns, cellWidth) = metrics(forWidth: bounds.width)
        let rows = Int(ceil(Double(subviews.count) / Double(columns)))
        let naturalRowHeight = subviews
            .map { $0.sizeThatFits(.init(width: cellWidth, height: nil)).height }
            .max() ?? 0
        // Grow rows to fill the height on offer. Side by side with About the row
        // is as tall as the taller of the two, and tiles that kept their natural
        // height left a gap under them; sharing the surplus keeps the two columns
        // ending on the same line however many ratings there are.
        let available = bounds.height - spacing * CGFloat(max(0, rows - 1))
        let rowHeight = rows > 0
            ? max(naturalRowHeight, available / CGFloat(rows))
            : naturalRowHeight
        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            let row = index / columns
            let origin = CGPoint(
                x: bounds.minX + CGFloat(column) * (cellWidth + spacing),
                y: bounds.minY + CGFloat(row) * (rowHeight + spacing)
            )
            subview.place(
                at: origin,
                proposal: ProposedViewSize(width: cellWidth, height: rowHeight)
            )
        }
    }
}
#endif
