import AppRuntime
import CoreModels
import FeatureHomeCore
import Foundation
import MetadataKit
import TraktService

/// Builds the Related row's loader for a detail page.
///
/// Returns `nil` when there are no accounts to search: the row shows only titles
/// the viewer actually has, so with nothing to search there is nothing to show and
/// the whole feature stays inert rather than spending provider calls.
@MainActor
func makeRelatedTitlesLoader(in accounts: [ResolvedAccount]) -> RelatedTitlesLoader? {
    guard let search = relatedTitleLibrarySearch(in: accounts) else { return nil }
    return RelatedTitlesLoader(
        resolver: .production(traktClientID: TraktConfig.resolved().clientID),
        search: search
    )
}
