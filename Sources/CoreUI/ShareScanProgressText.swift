#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Builds the `Text` for a share scan's optional trailing progress detail
/// (`ShareScanState.progressDetail`). Centralized so the three consumers
/// (`FeatureHome.HomeView`'s status pill, `FeatureSettings.ServerDetailView`,
/// and `AppShelliOS`'s share section) produce byte-for-byte the same catalog
/// keys rather than each writing its own slightly different interpolation.
///
/// The counts are interpolated as `Int`, not pre-formatted `String`s, so each
/// stays a real, pluralizable catalog substitution and picks up SwiftUI's
/// locale-aware grouping by default. The one exception is `.enriching`'s
/// `total`, which must render WITHOUT grouping to match its pre-padded `done`
/// string's fixed width under a monospaced-digit font — see
/// `ScanProgressDetail.enriching`'s doc.
public func scanProgressDetailText(_ detail: ScanProgressDetail) -> Text {
    switch detail {
    case let .foldersAndItems(folders, items):
        return Text(
            "\(folders) folders · \(items) items",
            comment: "Share scan progress: directories walked and media items found so far, while scanning."
        )
    case let .folders(count):
        return Text(
            "\(count) folders",
            comment: "Share scan progress: directories walked so far, while scanning (shown before any media item has been found yet)."
        )
    case let .items(count):
        return Text(
            "\(count) items",
            comment: "Share scan progress: media items found so far, while scanning (shown once at least one directory or item is known)."
        )
    case let .enriching(done, total):
        return Text(
            "\(done) of \(total, format: .number.grouping(.never))",
            comment: "Share enrichment progress: items enriched so far out of the pass's total. `done` arrives pre-padded to a fixed width; `total` must stay ungrouped to match."
        )
    }
}
#endif
