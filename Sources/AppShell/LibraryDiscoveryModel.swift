#if canImport(SwiftUI)
import Foundation
import Observation
import CoreModels
import FeatureHome

/// Loads the full set of libraries across every active account for the Settings
/// "Home Libraries" checklist. Lives in the composition root because it drives
/// the provider-agnostic `HomeAggregator`; `FeatureSettings` only ever sees the
/// resulting `[AggregatedLibrary]` data, never a provider.
@MainActor
@Observable
final class LibraryDiscoveryModel {
    private(set) var state: LoadState<[AggregatedLibrary]> = .idle

    private let aggregator = HomeAggregator()

    /// Discovers libraries across `accounts`, resiliently. Always reloads so the
    /// checklist reflects servers added/removed since it was last opened.
    func load(from accounts: [ResolvedAccount]) async {
        state = .loading
        let libraries = await aggregator.libraries(from: accounts)
        state = libraries.isEmpty ? .empty : .loaded(libraries)
    }
}
#endif
