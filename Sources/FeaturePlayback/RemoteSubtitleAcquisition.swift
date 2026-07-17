import CoreModels
import CoreNetworking

/// Menu/host side effects that ``RemoteSubtitleAcquisition`` drives after a
/// search or download. Kept as a weak-referenced protocol so the acquisition
/// object (owned by the view model) never forms a retain cycle back to it.
///
/// All members run on the main actor: acquisition mirrors the view model's
/// actor so `controls` mutation and menu rebuilds stay hop-free; only the
/// network fetch/poll runs off-actor inside the detached tasks.
@MainActor
protocol RemoteSubtitleAcquisitionHost: AnyObject {
    /// Publishes the manual search/download UI state (→ `controls.subtitleDownloadState`).
    func setSubtitleDownloadState(_ state: SubtitleDownloadState)
    /// Registers a freshly downloaded sidecar in the track menu, returning its
    /// assigned synthetic id (never colliding with engine/provider stream ids).
    func hotLoadDownloadedSubtitle(_ track: MediaTrack, preferredLanguage: String?, forced: Bool) -> Int
    /// Selects a menu subtitle track by id.
    func selectDownloadedSubtitle(id: Int, userInitiated: Bool)
    /// Whether the primary subtitle is currently "Off" — auto-download only
    /// auto-selects the fetched track when nothing is already shown.
    var isPrimarySubtitleOff: Bool { get }
}

/// Owns manual + automatic remote-subtitle **acquisition** for a single playback
/// session: the server-proxied search, the download, and the post-download poll
/// that waits for the server to attach the new sidecar before hot-loading it.
///
/// Extracted from `PlayerViewModel` so the fetch/poll task lifecycle and its
/// cancellation semantics (manual search and download/auto-download share a
/// single in-flight download slot, so one supersedes the other) live in one
/// directly testable place. The host still owns the track menu — this collaborator
/// drives hot-load registration + selection through ``RemoteSubtitleAcquisitionHost``.
@MainActor
final class RemoteSubtitleAcquisition {
    private let provider: any MediaProvider
    private let itemID: String
    private weak var host: RemoteSubtitleAcquisitionHost?

    /// The language used for the most recent manual search, so the per-search
    /// SDH/Forced toggle can re-run it (``refreshSearch(defaultLanguage:preference:)``).
    private(set) var lastSearchLanguage: String?
    /// In-flight manual search (separate from the download task so a search and a
    /// download can be in flight at once without cancelling each other).
    private var searchTask: Task<Void, Never>?
    /// In-flight download — shared by the manual and automatic download paths so a
    /// newer download always supersedes an older one.
    private var downloadTask: Task<Void, Never>?

    init(provider: any MediaProvider, itemID: String, host: RemoteSubtitleAcquisitionHost) {
        self.provider = provider
        self.itemID = itemID
        self.host = host
    }

    /// Whether the active provider supports server-proxied subtitle search &
    /// download (Jellyfin/Plex advertise `.remoteSubtitles`; SMB does not).
    var providerSupportsRemoteSubtitles: Bool {
        (provider as? CapabilityReporting)?.capabilities.contains(.remoteSubtitles) ?? false
    }

    /// Manually search the server's subtitle source for `requestedLanguage` (or
    /// `defaultLanguage` when `nil`), honouring the SDH/Forced `preference`.
    /// Publishes results through the host's download state.
    func search(requestedLanguage: String?, defaultLanguage: String?, preference: SubtitleSearchPreference) {
        guard providerSupportsRemoteSubtitles else {
            host?.setSubtitleDownloadState(.empty)
            return
        }
        let language = requestedLanguage ?? defaultLanguage
        guard let language, !language.isEmpty else {
            host?.setSubtitleDownloadState(.empty)
            return
        }
        lastSearchLanguage = language
        let provider = self.provider
        let itemID = self.itemID
        host?.setSubtitleDownloadState(.searching)
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                let raw = try await provider.remoteSubtitleSearch(itemID: itemID, language: language, preference: preference)
                let ranked = raw.applying(preference)
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    self?.host?.setSubtitleDownloadState(ranked.isEmpty ? .empty : .results(ranked))
                }
            } catch is CancellationError {
                return
            } catch {
                PlozzLog.playback.debug("Manual subtitle search failed (non-fatal)")
                await MainActor.run { [weak self] in
                    self?.host?.setSubtitleDownloadState(.failed)
                }
            }
        }
    }

    /// Re-runs the last manual search (used after the viewer flips the per-search
    /// SDH/Forced toggle so the results reflect the new preference).
    func refreshSearch(defaultLanguage: String?, preference: SubtitleSearchPreference) {
        search(requestedLanguage: lastSearchLanguage, defaultLanguage: defaultLanguage, preference: preference)
    }

    /// Downloads the chosen remote subtitle onto the server, then hot-loads it into
    /// the running player so it appears immediately (no replay needed).
    func download(_ subtitle: RemoteSubtitle, preference: SubtitleSearchPreference) {
        guard !subtitle.id.isEmpty else { return }
        let provider = self.provider
        let itemID = self.itemID
        let language = subtitle.language ?? lastSearchLanguage
        host?.setSubtitleDownloadState(.downloading(subtitle.id))
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            do {
                // Snapshot the item's existing server-side subtitle ids first, so the
                // poll can tell the *newly downloaded* sidecar apart from ones that
                // were already attached (which would otherwise be mistaken for the
                // download and duplicated in the menu).
                let baseline = await Self.existingSubtitleTrackIDs(provider: provider, itemID: itemID)
                try await provider.downloadRemoteSubtitle(itemID: itemID, subtitleID: subtitle.id)
                let track = try await Self.pollForNewSubtitleTrack(
                    provider: provider, itemID: itemID, language: language, knownIDs: baseline
                )
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, let host = self.host else { return }
                    if let track {
                        let id = host.hotLoadDownloadedSubtitle(track, preferredLanguage: language, forced: subtitle.isForced)
                        host.selectDownloadedSubtitle(id: id, userInitiated: true)
                        host.setSubtitleDownloadState(.added)
                    } else {
                        // Downloaded but the server hasn't surfaced it yet; it will
                        // appear on the next natural track refresh / replay.
                        host.setSubtitleDownloadState(.added)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                PlozzLog.playback.debug("Subtitle download failed (non-fatal)")
                await MainActor.run { [weak self] in
                    self?.host?.setSubtitleDownloadState(.failed)
                }
            }
        }
    }

    /// Background search+download for the resolved auto-download decision (the host
    /// decides *whether* to auto-download; this performs it). Best-effort and
    /// silent: it never blocks play and never publishes a download UI state.
    /// Requires a genuine language match so it can never attach a wrong-language
    /// subtitle, and only auto-selects the result when nothing is currently shown.
    func autoDownload(language: String, mode: SubtitleMode, preference: SubtitleSearchPreference) {
        let provider = self.provider
        let itemID = self.itemID
        downloadTask = Task { [weak self] in
            do {
                let results = try await provider.remoteSubtitleSearch(itemID: itemID, language: language, preference: preference)
                // Require a genuine language match so auto-download can never attach
                // a wrong-language subtitle.
                guard let best = results.bestMatch(
                    forLanguage: language, mode: mode,
                    preference: preference, requireLanguageMatch: true
                ), !best.id.isEmpty else { return }
                // Baseline of already-attached subtitle ids so the poll only picks up
                // the newly-downloaded one.
                let baseline = await Self.existingSubtitleTrackIDs(provider: provider, itemID: itemID)
                try await provider.downloadRemoteSubtitle(itemID: itemID, subtitleID: best.id)
                PlozzLog.playback.info("Auto-downloaded subtitle for item")
                let track = try await Self.pollForNewSubtitleTrack(
                    provider: provider, itemID: itemID, language: language, knownIDs: baseline
                )
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, let host = self.host, let track else { return }
                    // Only hot-load; don't yank the viewer's current selection —
                    // register the row so they can pick it, and select it only if
                    // nothing is currently shown.
                    let id = host.hotLoadDownloadedSubtitle(track, preferredLanguage: language, forced: best.isForced)
                    if host.isPrimarySubtitleOff {
                        host.selectDownloadedSubtitle(id: id, userInitiated: false)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                PlozzLog.playback.debug("Auto subtitle download failed (non-fatal)")
            }
        }
    }

    /// Cancels any in-flight search and download (playback teardown).
    func cancelAll() {
        searchTask?.cancel()
        searchTask = nil
        downloadTask?.cancel()
        downloadTask = nil
    }

    /// The item's current server-side subtitle-track ids (best-effort, empty on
    /// failure), used as the "already attached" baseline for ``pollForNewSubtitleTrack``.
    nonisolated static func existingSubtitleTrackIDs(provider: any MediaProvider, itemID: String) async -> Set<Int> {
        let tracks = (try? await provider.subtitleTracks(forItemID: itemID)) ?? []
        return Set(tracks.map(\.id))
    }

    /// Polls the item's subtitle tracks (the server attaches asynchronously) for a
    /// *new* text sidecar — one whose id isn't in `knownIDs` (the pre-download
    /// baseline) — preferring a language match, returning `nil` after a bounded
    /// number of attempts. Nonisolated so it runs off the main actor.
    nonisolated static func pollForNewSubtitleTrack(
        provider: any MediaProvider,
        itemID: String,
        language: String?,
        knownIDs: Set<Int> = []
    ) async throws -> MediaTrack? {
        for attempt in 0..<4 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            try Task.checkCancellation()
            let tracks = (try? await provider.subtitleTracks(forItemID: itemID)) ?? []
            // Only consider text sidecars that appeared *after* the download.
            let newTextSubs = tracks.filter {
                $0.deliverySource != nil
                    && !$0.isImageBasedSubtitle
                    && !knownIDs.contains($0.id)
            }
            // Prefer a language match among the new tracks; else any new sidecar.
            if let language, !language.isEmpty,
               let match = newTextSubs.first(where: { LanguageMatch.matches($0.language, language) }) {
                return match
            }
            if let any = newTextSubs.last { return any }
        }
        return nil
    }
}
