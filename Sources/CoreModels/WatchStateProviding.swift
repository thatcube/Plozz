import Foundation

/// Optional capability a `MediaProvider` adopts to let the user toggle an item's
/// played / "watched" state on the server.
///
/// Detected at runtime via `provider as? WatchStateProviding`, mirroring how
/// music support is detected via `as? MusicProvider`. This keeps the base
/// `MediaProvider` contract unchanged — providers (and test doubles) that can't
/// mutate watched state simply don't conform, and the UI hides the action.
///
/// **Why this writes through the backend (and never fakes a local flag):** the
/// media server is the single source of truth for watched state. Writing to it
/// means any server-side sync the user has configured — e.g. the Jellyfin or
/// Plex **Trakt** plugin — picks the change up automatically, and every other
/// client sees it too.
public protocol WatchStateProviding: Sendable {
    /// Marks `itemID` played (`true`) or unplayed (`false`) on the server.
    ///
    /// For a container item (a season or series id) the backend cascades the
    /// change to its children, so a whole season can be marked watched with one
    /// call where the provider supports it.
    func setPlayed(_ played: Bool, itemID: String) async throws
}

/// Refinement of ``WatchStateProviding`` for a provider whose played state is
/// stored **locally** (no authoritative server), where last-writer ordering must
/// honor the play's *real* event time rather than the moment the write drains.
///
/// The cross-server watch outbox can queue a played write and drain it much later
/// (server asleep, app offline, or the account still resolving at launch). A
/// server-backed provider (Plex, Jellyfin) doesn't care — its server owns
/// recency — so it conforms to ``WatchStateProviding`` alone. A local store (the
/// SMB share) must stamp the write with `capturedAt` so a late-draining *stale*
/// played write can't clobber genuinely newer resume / in-progress state.
///
/// Detected at runtime via `provider as? PlayedStateWriting` (preferred over the
/// timestamp-less ``WatchStateProviding/setPlayed(_:itemID:)`` when present).
public protocol PlayedStateWriting: WatchStateProviding {
    /// Marks `itemID` played/unplayed, stamped with the play's real time
    /// (`capturedAt`) for local last-writer-wins ordering — see
    /// ``ResumeStateWriting/setResumePosition(_:itemID:capturedAt:)`` for the
    /// same rationale applied to resume writes.
    func setPlayed(_ played: Bool, itemID: String, capturedAt: Date) async throws
}

/// Optional capability a `MediaProvider` adopts to write a **resume position**
/// (seconds) to the server **without an active playback session** — the seam the
/// cross-server watch-state outbox uses to converge a server that the user did not
/// launch from (e.g. the Jellyfin copy when the title was watched on Plex).
///
/// Detected at runtime via `provider as? ResumeStateWriting`, mirroring
/// ``WatchStateProviding``. Jellyfin writes the position via its playback-progress
/// (`/Sessions/Playing/Stopped`) endpoint; Plex via `/:/timeline`.
public protocol ResumeStateWriting: Sendable {
    /// Sets the saved resume position (seconds) for `itemID` on this server. A
    /// position of `0` clears the resume point (title finished / start over).
    ///
    /// `capturedAt` is *when the play that produced this position actually
    /// happened* — not when the write is being flushed. It matters for the
    /// server's recency stamp (Jellyfin's `LastPlayedDate`, which orders its
    /// Continue Watching row): a mutation that was queued offline and drained
    /// hours later must converge with its original play time, otherwise a stale
    /// play jumps to the top of Continue Watching on the next Home load.
    func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws
}
