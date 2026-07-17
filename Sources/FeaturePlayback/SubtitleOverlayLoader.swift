import CoreModels
import CoreNetworking
import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Owns the **subtitle overlay cue-load pipeline**: the in-flight fetch tasks for
/// the primary and secondary (dual) text sidecars, plus the fetch → decode →
/// parse → detect-language → apply steps that feed Plozz's own subtitle overlay.
///
/// This is the mechanism half of subtitle rendering, split out of
/// `PlayerViewModel` so the task lifecycle (cancel-on-reselect, stale-selection
/// guards, best-effort failure handling) lives in one focused collaborator. The
/// view model keeps ownership of *selection* (which track, engine routing,
/// styling, live-feed mode) and simply asks this loader to (re)load or clear the
/// overlay streams; the loader calls back through a weak `host` for the model
/// side effects (applying cues, recording a detected language, refreshing the
/// menu, secondary status).
///
/// The network fetch is injected (`fetch`) so the parse/apply/guard behaviour is
/// directly unit-testable with canned sidecar bytes — the default hits
/// `URLSession.shared`. The loader never retains the view model (weak host), so
/// it can't extend its lifetime.
@MainActor
final class SubtitleOverlayLoader {

    /// Parsed sidecar plus the facts the caller needs to decide whether to apply
    /// it (a language guess for an untagged track, the byte count for logging).
    struct ParsedSubtitlePayload: Sendable {
        let stream: SubtitleCueStream
        let detectedLanguage: String?
        let byteCount: Int
    }

    private weak var host: SubtitleOverlayLoaderHost?
    private let fetch: @Sendable (URL) async throws -> Data
    private var primaryTask: Task<Void, Never>?
    private var secondaryTask: Task<Void, Never>?

    init(
        host: SubtitleOverlayLoaderHost,
        fetch: @escaping @Sendable (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }
    ) {
        self.host = host
        self.fetch = fetch
    }

    // MARK: - Cancellation

    /// Cancels the in-flight **primary** fetch without touching the overlay cues
    /// (used when an engine will draw the subtitle itself — live-feed mode).
    func cancelPrimary() {
        primaryTask?.cancel()
        primaryTask = nil
    }

    /// Cancels the in-flight **secondary** fetch without clearing the second line.
    func cancelSecondary() {
        secondaryTask?.cancel()
        secondaryTask = nil
    }

    /// Cancels both fetches (engine reset / teardown).
    func cancelAll() {
        cancelPrimary()
        cancelSecondary()
    }

    /// Cancels any in-flight primary fetch and clears the **primary** overlay
    /// (subtitles off, or switching to an engine that draws its own). Leaves the
    /// secondary/dual line untouched — it's an independent overlay stream.
    func clearPrimary() {
        cancelPrimary()
        host?.overlayApplyPrimaryCues(nil)
    }

    // MARK: - Primary

    /// Fetches the selected text sidecar, parses it to cues off the main actor,
    /// and loads it into the overlay — unless the selection changed mid-fetch.
    /// Best-effort: a failure simply leaves no overlay cues rather than wedging.
    func loadPrimary(_ track: MediaTrack) {
        cancelPrimary()
        // Clear only the primary stream; a selected dual/secondary line survives a
        // primary track change.
        host?.overlayApplyPrimaryCues(nil)
        guard track.deliverySource != nil else {
            // Embedded text without a sidecar source: container extraction arrives
            // with the Plozzigen cue path; leave nothing showing until then.
            PlozzLog.playback.debug("Selected subtitle has no sidecar source; overlay not loaded")
            return
        }
        let id = track.id
        let language = track.language
        let title = track.displayTitle
        let forced = track.isForced
        // Only spend a detection pass when the provider gave us no language tag
        // and we haven't already guessed one for this track this session.
        let needsDetection = (language == nil) && (host?.overlayDetectedLanguage(for: id) == nil)
        primaryTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self, let host = self.host else { return }
            do {
                guard let url = try await host.overlayResolveDeliveryURL(track) else { return }
                guard let payload = try await self.fetchPayload(
                    from: url,
                    id: id,
                    language: language,
                    title: title,
                    forced: forced,
                    shouldDetectLanguage: needsDetection
                ) else {
                    guard host.primarySubtitleSelectionID == id else { return }
                    #if DEBUG
                    host.overlaySetPrimaryDiagnostic(route: "overlay · decode-fail", cues: nil)
                    #endif
                    return
                }
                try Task.checkCancellation()
                let storedNew = payload.detectedLanguage != nil
                    && host.overlayDetectedLanguage(for: id) == nil
                if let detected = payload.detectedLanguage, storedNew {
                    host.overlayRecordDetectedLanguage(detected, for: id)
                }
                if host.primarySubtitleSelectionID == id {
                    host.overlayApplyPrimaryCues(payload.stream)
                    #if DEBUG
                    host.overlaySetPrimaryDiagnostic(route: "overlay", cues: payload.stream.cues.count)
                    #endif
                }
                if storedNew { host.overlayReloadTrackOptions() }
            } catch is CancellationError {
                // Selection changed; the newer selection owns the overlay.
            } catch {
                PlozzLog.playback.debug("Overlay subtitle fetch failed (non-fatal)")
                guard host.primarySubtitleSelectionID == id else { return }
                #if DEBUG
                host.overlaySetPrimaryDiagnostic(route: "overlay · fetch-fail", cues: nil)
                #endif
            }
        }
    }

    // MARK: - Secondary (dual)

    /// Fetches + parses the secondary sidecar off the main actor and loads it into
    /// the overlay's secondary stream, unless the secondary selection changed
    /// mid-fetch. Mirrors ``loadPrimary(_:)`` but never touches the primary.
    /// Publishes a load status so the picker row can show loading / cue count /
    /// unavailable. Best-effort: a failure just leaves the second line empty.
    func loadSecondary(_ track: MediaTrack) {
        cancelSecondary()
        host?.overlayApplySecondaryCues(nil)
        guard track.deliverySource != nil else {
            host?.overlaySetSecondaryStatus(.unavailable)
            return
        }
        host?.overlaySetSecondaryStatus(.loading)
        let id = track.id
        let language = track.language
        let title = track.displayTitle
        let forced = track.isForced
        secondaryTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self, let host = self.host else { return }
            do {
                guard let url = try await host.overlayResolveDeliveryURL(track),
                      let payload = try await self.fetchPayload(
                          from: url,
                          id: id,
                          language: language,
                          title: title,
                          forced: forced,
                          shouldDetectLanguage: false
                      ) else {
                    guard host.secondarySubtitleSelectionID == id else { return }
                    host.overlaySetSecondaryStatus(.unavailable)
                    return
                }
                try Task.checkCancellation()
                #if DEBUG
                let range = payload.stream.cues.isEmpty
                    ? "none"
                    : "\(Int(payload.stream.cues.first!.start))s–\(Int(payload.stream.cues.last!.end))s"
                PlozzLog.playback.debug(
                    "Secondary track \(id): fetched \(payload.byteCount) bytes → \(payload.stream.cues.count) cues (\(range))"
                )
                #endif
                guard host.secondarySubtitleSelectionID == id else { return }
                host.overlayApplySecondaryCues(payload.stream)
                host.overlaySetSecondaryStatus(.loaded(cueCount: payload.stream.cues.count))
            } catch is CancellationError {
                // Selection changed; the newer secondary owns the stream.
            } catch {
                PlozzLog.playback.debug("Secondary track \(id) sidecar fetch failed (non-fatal): \(error.localizedDescription)")
                guard host.secondarySubtitleSelectionID == id else { return }
                host.overlaySetSecondaryStatus(.unavailable)
            }
        }
    }

    // MARK: - Fetch / parse (off the main actor)

    private nonisolated func fetchPayload(
        from url: URL,
        id: Int,
        language: String?,
        title: String,
        forced: Bool,
        shouldDetectLanguage: Bool
    ) async throws -> ParsedSubtitlePayload? {
        let data = try await fetch(url)
        try Task.checkCancellation()
        guard let text = SubtitleCueParser.decodeText(data) else {
            PlozzLog.playback.error(
                "Subtitle sidecar decode failed (\(data.count) bytes); unknown text encoding"
            )
            return nil
        }
        let stream = SubtitleCueParser.parse(
            text,
            id: id,
            language: language,
            title: title,
            sourceTrackID: id,
            isForced: forced
        )
        try Task.checkCancellation()
        let detected = shouldDetectLanguage ? Self.detectLanguage(in: stream.cues) : nil
        return ParsedSubtitlePayload(
            stream: stream,
            detectedLanguage: detected,
            byteCount: data.count
        )
    }

    /// Best-effort on-device language guess for an untagged text subtitle, from a
    /// sample of its parsed cue text. Runs off the main actor (`nonisolated`).
    /// Returns a BCP-47-ish code (e.g. `en`, `es`, `zh-Hans`) or `nil` when there
    /// isn't enough text to be confident. Bitmap cues have no `text`, so they
    /// naturally yield `nil` (they need OCR, out of scope here).
    nonisolated static func detectLanguage(in cues: [SubtitleCue]) -> String? {
        #if canImport(NaturalLanguage)
        var sample = ""
        for cue in cues {
            guard let line = cue.text, !line.isEmpty else { continue }
            sample += line
            sample += "\n"
            if sample.count > 4000 { break }
        }
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too little text to classify reliably — don't risk a wrong label.
        guard trimmed.count >= 24 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
        #else
        return nil
        #endif
    }
}

/// Weak back-channel from ``SubtitleOverlayLoader`` to the view model for the
/// selection facts it must re-check (stale-guard) and the model side effects it
/// triggers. `@MainActor` so the loader's tasks call it without hops; `AnyObject`
/// + weak so the loader never retains the view model.
@MainActor
protocol SubtitleOverlayLoaderHost: AnyObject {
    /// The currently selected primary subtitle track id (nil = off) — used to drop
    /// a fetch whose selection was superseded mid-flight.
    var primarySubtitleSelectionID: Int? { get }
    /// The currently selected secondary (dual) subtitle track id (nil = off).
    var secondarySubtitleSelectionID: Int? { get }

    /// Resolves a track's delivery source to a concrete URL (local file or an
    /// authenticated HTTP locator).
    func overlayResolveDeliveryURL(_ track: MediaTrack) async throws -> URL?

    /// Applies (or clears, with `nil`) the primary overlay cue stream and refreshes
    /// the subtitle-delay availability that depends on it.
    func overlayApplyPrimaryCues(_ stream: SubtitleCueStream?)
    /// Applies (or clears, with `nil`) the secondary overlay cue stream.
    func overlayApplySecondaryCues(_ stream: SubtitleCueStream?)

    /// A previously detected language for an untagged track, if any.
    func overlayDetectedLanguage(for id: Int) -> String?
    /// Records a freshly detected language for an untagged track.
    func overlayRecordDetectedLanguage(_ language: String, for id: Int)

    /// Rebuilds the track menus (e.g. after a detected language changes a label).
    func overlayReloadTrackOptions()
    /// Publishes the secondary sidecar load status for the picker row.
    func overlaySetSecondaryStatus(_ status: SecondarySubtitleStatus)

    #if DEBUG
    /// Sets the on-screen primary-subtitle route diagnostic (DEBUG overlay).
    func overlaySetPrimaryDiagnostic(route: String, cues: Int?)
    #endif
}
