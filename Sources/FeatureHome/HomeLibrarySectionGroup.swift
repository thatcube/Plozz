import CoreModels

/// One library's unmerged Home block: the library itself (for the tappable
/// section header + routing into full browse) paired with its ordered content
/// rows (uniform base sections + any provider-native discovery hubs).
///
/// Produced by the aggregator only in **unmerged** mode; merged mode continues to
/// use the fixed `HomeRow`/`HomeRowKind` model untouched. Kept SwiftUI-free so it
/// stays testable on any platform.
public struct HomeLibrarySectionGroup: Identifiable, Equatable, Sendable {
    /// The owning library — drives the section heading (name + provider mark) and
    /// the "browse everything" destination when the header is selected.
    public let library: AggregatedLibrary

    /// The library's rows, in display order. Never contains an empty-items row
    /// (the aggregator drops those) so the view never draws a headed-but-blank row.
    public var sections: [LibrarySection]

    /// Stable identity for SwiftUI — the library's cross-account key.
    public var id: String { library.key }

    public init(library: AggregatedLibrary, sections: [LibrarySection]) {
        self.library = library
        self.sections = sections
    }

    /// Total cards across all of the group's rows — used for skeleton sizing and
    /// telemetry.
    public var cardCount: Int { sections.reduce(0) { $0 + $1.items.count } }

    /// Whether the group has anything to show (at least one non-empty row).
    public var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }
}
