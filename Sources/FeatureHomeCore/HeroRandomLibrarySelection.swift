import CoreModels

/// Resolves persisted Random-source choices against Home's loaded library catalog.
public enum HeroRandomLibrarySelection {
    public static func resolve(
        _ libraries: [AggregatedLibrary],
        settings: HeroSettings?,
        isVisible: (String) -> Bool
    ) -> [HeroRandomLibrary] {
        guard let settings,
              settings.isActive,
              settings.isEnabled(.randomFromLibrary) else {
            return []
        }

        let configuredKeys = settings.randomLibraryKeys
        return libraries.compactMap { library in
            guard library.library.kind == .movie
                    || library.library.kind == .series else {
                return nil
            }
            let selected = configuredKeys.isEmpty
                ? isVisible(library.key)
                : configuredKeys.contains(library.key)
            guard selected else { return nil }
            return HeroRandomLibrary(
                accountID: library.accountID,
                libraryID: library.library.id,
                kind: library.library.kind
            )
        }
        .sorted {
            ($0.accountID, $0.libraryID) < ($1.accountID, $1.libraryID)
        }
    }
}
