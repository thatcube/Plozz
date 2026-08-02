import AppRuntime
import CoreModels
import FeatureHomeCore
import Foundation
import MetadataKit
import TraktService

/// Builds the Related row's loader for a detail page.
///
/// Returns `nil` when there are no active accounts because there is no library
/// ownership index/search context to compose the row against.
@MainActor
func makeRelatedTitlesLoader(
    in accounts: [ResolvedAccount],
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
    displayMode: RelatedTitlesLoader.DisplayMode = .libraryOnly
) -> RelatedTitlesLoader? {
    guard let search = relatedTitleLibrarySearch(in: accounts) else { return nil }
    return RelatedTitlesLoader(
        resolver: .production(traktClientID: TraktConfig.resolved().clientID),
        search: search,
        indexedLibrarySources: identitySources,
        displayMode: displayMode
    )
}
