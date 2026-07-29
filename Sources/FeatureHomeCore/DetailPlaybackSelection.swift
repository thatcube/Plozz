import Foundation
import CoreModels

/// Platform-neutral detail-page server and media-version selection.
public enum DetailPlaybackSelection {
    public static func serverChoices(from sources: [MediaSourceRef]) -> [MediaSourceRef] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.accountID).inserted }
    }

    public static func preferredSource(
        sourceOverride: String?,
        libraryOrigin: String?,
        itemSourceAccountID: String?,
        sources: [MediaSourceRef],
        capabilities: MediaCapabilities
    ) -> MediaSourceRef? {
        let choices = serverChoices(from: sources)
        guard choices.count > 1 || sources.count > 1 else { return nil }
        if let sourceOverride,
           let match = choices.first(where: { $0.accountID == sourceOverride }) {
            return match
        }
        if let libraryOrigin,
           let match = choices.first(where: { $0.accountID == libraryOrigin }) {
            return match
        }
        return CrossSourceSelector.bestSelection(
            from: choices,
            capabilities: capabilities,
            preferring: itemSourceAccountID
        )?.source ?? choices.first ?? sources.first
    }

    public static func versions(
        for item: MediaItem,
        sources: [MediaSourceRef],
        activeAccountID: String?
    ) -> [MediaVersion] {
        guard let activeAccountID else {
            return item.versions.sortedForPicker()
        }
        let active = sources.filter { $0.accountID == activeAccountID }
        guard !active.isEmpty else {
            return item.versions.sortedForPicker()
        }
        return active.flatMap(\.versions).sortedForPicker()
    }

    public static func preferredVersionID(
        for item: MediaItem,
        versions: [MediaVersion],
        versionOverride: String?,
        preferences: any VersionPreferenceStoring,
        capabilities: MediaCapabilities
    ) -> String? {
        guard versions.count > 1 else { return nil }
        if let versionOverride,
           versions.contains(where: { $0.id == versionOverride }) {
            return versionOverride
        }
        let key = versionPreferenceKey(for: item)
        // An exact file id first: for a movie you return to, that IS the choice.
        let remembered = preferences.preferredVersionID(forTitle: key)
        if let remembered, versions.contains(where: { $0.id == remembered }) {
            return remembered
        }
        // Otherwise the remembered SHAPE. This is what carries a choice across a
        // series: every episode's files have their own provider ids, so the id
        // above can never match another episode — only "2160p Dolby Vision
        // Bluray" can. Falls through when nothing is close enough, because
        // forcing a bad match is worse than the device-recommended pick.
        if let descriptor = preferences.preferredVersionDescriptor(forTitle: key),
           let match = versions.bestMatch(for: descriptor) {
            return match.id
        }
        return versions.recommendedSelection(for: capabilities)?.id
    }

    /// The item as it should actually be played: the show's remembered version
    /// resolved against THIS item's own files.
    ///
    /// Exists so version resolution can be applied by construction rather than by
    /// remembering. `preferredVersionID` was already shared, but every play path
    /// had to opt in by calling it — and four of them didn't: the tvOS and iOS
    /// episode auto-advance, and both platforms' Continue Watching rows. Each
    /// handed the player an item straight from the provider, so it played the
    /// server default however deliberately the viewer had chosen otherwise, and
    /// the bug had to be found once per path.
    ///
    /// A no-op when the item already carries an explicit choice, or has nothing
    /// to choose between.
    public static func playbackReady(
        _ item: MediaItem,
        preferences: any VersionPreferenceStoring,
        capabilities: MediaCapabilities
    ) -> MediaItem {
        guard item.selectedVersionID == nil, item.versions.count > 1 else { return item }
        guard let id = preferredVersionID(
            for: item,
            versions: item.versions,
            versionOverride: nil,
            preferences: preferences,
            capabilities: capabilities
        ) else { return item }
        return item.selectingVersion(id)
    }

    public static func versionPreferenceKey(for item: MediaItem) -> String {
        item.seriesID ?? item.id
    }

    public static func playItem(
        for item: MediaItem,
        sources: [MediaSourceRef],
        activeAccountID: String?,
        versionID: String?,
        explicit: Bool
    ) -> MediaItem {
        MediaItem.retargetedForPlayback(
            item: item,
            sources: sources,
            activeAccountID: activeAccountID,
            versionID: versionID,
            explicit: explicit
        )
    }
}

public func preferredDetailSource(
    sourceOverride: String?,
    libraryOrigin: String?,
    itemSourceAccountID: String?,
    sources: [MediaSourceRef],
    serverChoices: [MediaSourceRef],
    capabilities: MediaCapabilities
) -> MediaSourceRef? {
    DetailPlaybackSelection.preferredSource(
        sourceOverride: sourceOverride,
        libraryOrigin: libraryOrigin,
        itemSourceAccountID: itemSourceAccountID,
        sources: sources.isEmpty ? serverChoices : sources,
        capabilities: capabilities
    )
}
