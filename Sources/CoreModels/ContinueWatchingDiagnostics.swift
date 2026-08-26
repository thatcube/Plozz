import Foundation

/// On-device **Continue Watching sync** telemetry. Answers one question that
/// cannot be answered by reading code: *at the moment the row is wrong, which
/// link in the chain is lying?*
///
/// The chain has four links, and a wrong row can come from any of them:
///
///  1. **What the server returned.** A title the viewer already watched (or
///     removed) can still be in the server's own resume feed. Plex's
///     `/library/onDeck` in particular is *not* the modern Continue Watching hub
///     and does not honour "Remove from Continue Watching", so a row built from
///     it legitimately disagrees with what the Plex app shows.
///  2. **Whether our write ever landed.** Resume/scrobble writes are fire-and-
///     forget; a rejected or never-sent write leaves the server's idea of the
///     title untouched forever.
///  3. **What the local overlay did to the fetched row.** The overlay may drop a
///     card, restamp it — or match nothing at all, which is invisible today.
///  4. **Whether Home was ever told to look again.** A row that is never
///     re-fetched cannot be stale-checked, however correct every layer above is.
///
/// Every line is tagged `CWSYNC` and rides ``FanoutDiagnostics``' gate, so it
/// inherits the same three guarantees: **off** in shipped builds unless launched
/// with `PLZXFAN_STDOUT=1`, **never** blocking or altering the path it observes,
/// and **secret-safe** (ids, titles and counts only — never tokens or URLs
/// carrying one).
///
/// Stream it:
/// `xcrun devicectl device process launch --device <UDID> --console \
///   --environment-variables '{"PLZXFAN_STDOUT":"1"}' com.thatcube.Plozz`
/// or search `CWSYNC` in Console.app.
public enum ContinueWatchingDiagnostics {
    /// Emits one already-formatted line under the shared `PLZXFAN` gate.
    public static func emit(_ line: String) {
        FanoutDiagnostics.emit("CWSYNC " + line)
    }

    /// Whether telemetry is being collected. Callers use this to skip building
    /// diagnostic strings at all when the gate is closed.
    public static var isEnabled: Bool { FanoutDiagnostics.isEnabled }

    /// One row exactly as a backend reported it, before any mapping or merging.
    ///
    /// Deliberately mirrors the *server's* vocabulary rather than ``MediaItem``'s:
    /// the whole point is to see what the backend claimed, so a disagreement
    /// between the server and the screen can be pinned on one side or the other.
    public struct ServerRow: Sendable, Equatable {
        public var id: String
        public var kind: String
        public var title: String
        /// Milliseconds resumed to. `nil`/0 means the server is offering this as a
        /// *next up* suggestion rather than something genuinely in progress.
        public var viewOffsetMS: Int?
        public var durationMS: Int?
        /// How many times the server thinks this has been watched. **> 0 with no
        /// resume offset is the signature of an already-watched title** that the
        /// feed is still returning.
        public var viewCount: Int?
        public var lastViewedAt: Date?

        public init(
            id: String,
            kind: String,
            title: String,
            viewOffsetMS: Int? = nil,
            durationMS: Int? = nil,
            viewCount: Int? = nil,
            lastViewedAt: Date? = nil
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.viewOffsetMS = viewOffsetMS
            self.durationMS = durationMS
            self.viewCount = viewCount
            self.lastViewedAt = lastViewedAt
        }

        /// Fraction of the runtime the server's resume point sits at, when both
        /// numbers are known. A value near 1.0 on a title still being offered is
        /// the signature of a finish the server never converted into "watched".
        public var progressFraction: Double? {
            guard let durationMS, durationMS > 0, let viewOffsetMS else { return nil }
            return min(Double(viewOffsetMS) / Double(durationMS), 1)
        }

        /// The row looks like something the viewer already finished, yet the feed
        /// is still offering it. Either the server never recorded the finish, or
        /// the feed does not filter on watched state.
        public var looksAlreadyWatched: Bool {
            if (viewCount ?? 0) > 0, (viewOffsetMS ?? 0) == 0 { return true }
            if let fraction = progressFraction, fraction >= 0.95 { return true }
            return false
        }
    }

    // MARK: - Pure line builders (testable, no logging dependency)

    /// (1) What a backend's resume feed returned, verbatim.
    ///
    /// `suspect` counts rows that look already-watched. **A non-zero `suspect` is
    /// the answer to "why is a watched title still on my row"** — it came back
    /// that way, so no amount of client-side work would have removed it.
    public static func serverFeedLine(  // l10n:content — developer-facing diagnostic
        provider: String,  // l10n:content — developer-facing diagnostic
        accountID: String,
        endpoint: String,  // l10n:content — developer-facing diagnostic
        rows: [ServerRow]
    ) -> String {
        let suspect = rows.filter(\.looksAlreadyWatched)
        var line = "feed provider=\(provider) account=\(accountID) endpoint=\(endpoint) "
            + "rows=\(rows.count) suspect=\(suspect.count)"
        for row in rows {
            line += "\n  " + describe(row)
        }
        return line
    }

    /// One feed row, rendered compactly.
    public static func describe(_ row: ServerRow) -> String {  // l10n:content — developer-facing diagnostic
        var parts: [String] = ["id=\(row.id)", "kind=\(row.kind)"]
        parts.append("title=\"\(row.title)\"")
        parts.append("offset=" + (row.viewOffsetMS.map { "\($0)ms" } ?? "nil"))
        parts.append("duration=" + (row.durationMS.map { "\($0)ms" } ?? "nil"))
        parts.append("pct=" + (row.progressFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "nil"))
        parts.append("viewCount=" + (row.viewCount.map(String.init) ?? "nil"))
        parts.append("lastViewed=" + (row.lastViewedAt.map(timestamp) ?? "nil"))
        if row.looksAlreadyWatched { parts.append("<<SUSPECT-ALREADY-WATCHED") }
        return parts.joined(separator: " ")
    }

    /// (2) A watch-state write leaving the device, and what came back.
    ///
    /// `ok=false` means the server refused it. `ok=true` only means the request
    /// was *accepted* — several of these endpoints answer 200 to a call they then
    /// silently ignore, so a run of `ok=true` writes paired with a feed that never
    /// changes is itself the finding.
    public static func writeLine(  // l10n:content — developer-facing diagnostic
        provider: String,  // l10n:content — developer-facing diagnostic
        endpoint: String,  // l10n:content — developer-facing diagnostic
        itemID: String,
        detail: String,  // l10n:content — developer-facing diagnostic
        ok: Bool,
        error: String? = nil  // l10n:content — developer-facing diagnostic
    ) -> String {
        var line = "write provider=\(provider) endpoint=\(endpoint) id=\(itemID) \(detail) ok=\(ok)"
        if let error { line += " error=\(error)" }
        return line
    }

    /// (3) What the local overlay did to the fetched row.
    ///
    /// `unmatched` is the load-bearing number. It counts pending writes that
    /// matched **no card in the fetched feed** — the case the overlay cannot
    /// express, because it may drop or restamp a card but never invent one. A
    /// title just started from Search is exactly this: the server has not listed
    /// it yet, the overlay has the play but nowhere to put it, and the row stays
    /// silently wrong until a later refresh picks it up from the server.
    public static func overlayLine(  // l10n:content — developer-facing diagnostic
        fetched: Int,
        reconciled: Int,
        pending: Int,
        unmatched: [String]
    ) -> String {
        var line = "overlay fetched=\(fetched) reconciled=\(reconciled) pending=\(pending) "
            + "unmatched=\(unmatched.count)"
        if !unmatched.isEmpty {
            line += " <<PENDING-PLAY-WITH-NO-CARD targets=[\(unmatched.joined(separator: ", "))]"
        }
        return line
    }

    /// (4) A watch mutation reaching Home, and what Home decided to do about it.
    ///
    /// `onRow=false` with `reload=false` means the play was seen and then dropped
    /// on the floor: nothing on screen changed and nothing was scheduled to go
    /// and look again.
    public static func homeMutationLine(  // l10n:content — developer-facing diagnostic
        played: Bool?,
        resumePosition: TimeInterval?,
        onRow: Bool,
        reloadScheduled: Bool,
        state: String  // l10n:content — developer-facing diagnostic
    ) -> String {
        "home-mutation played=\(played.map(String.init(describing:)) ?? "nil") "
            + "resume=\(resumePosition.map { String(format: "%.0f", $0) } ?? "nil") "
            + "onRow=\(onRow) reloadScheduled=\(reloadScheduled) state=\(state)"
            + ((onRow || reloadScheduled) ? "" : " <<DROPPED-NO-ROW-UPDATE")
    }

    /// (4b) Why a Home refresh did or did not happen. A row that is never
    /// re-fetched cannot notice that the world moved on.
    public static func refreshLine(  // l10n:content — developer-facing diagnostic
        trigger: String,  // l10n:content — developer-facing diagnostic
        willReload: Bool,
        reason: String  // l10n:content — developer-facing diagnostic
    ) -> String {
        "refresh trigger=\(trigger) willReload=\(willReload) reason=\(reason)"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
