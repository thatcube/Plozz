import Foundation

/// Constants + copy for the combined **All Libraries** grid.
///
/// Collected in `CoreModels` rather than beside the view so the rail entry, the
/// browse root and the Settings arrangement list all name the same thing, and so
/// the reserved container id can never collide with a real server's.
public enum AllLibrariesBrowse {
    /// The container id handed to the aggregate. Never sent to a server — the
    /// aggregate pages each source by that source's own container id — but a
    /// non-empty, obviously-synthetic value makes it unmistakable in a log.
    public static let containerID = "plozz.allLibraries"

    /// Keys this grid's remembered sort separately from real libraries'.
    public static let sortKeySuffix = "allLibraries"

    public static let title = LocalizedStringResource(
        "allLibraries.title",
        defaultValue: "All Libraries",
        comment: "Title of the grid that browses every library at once."
    )

    public static let emptyTitle = LocalizedStringResource(
        "allLibraries.empty.title",
        defaultValue: "Nothing to browse",
        comment: "Shown when the combined All Libraries grid has no libraries to page."
    )

    public static let emptyMessage = LocalizedStringResource(
        "allLibraries.empty.message",
        defaultValue: "Turn on a server or a library in Settings to see everything here.",
        comment: "Guidance under the empty state of the combined All Libraries grid."
    )
}
