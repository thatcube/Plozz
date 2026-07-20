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
        let remembered = preferences.preferredVersionID(
            forTitle: versionPreferenceKey(for: item)
        )
        if let remembered, versions.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return versions.recommendedSelection(for: capabilities)?.id
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
