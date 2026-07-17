import Foundation
import CoreModels
import CoreNetworking
import MediaTransportCore

/// Owns share file-access policy for playback: resolving a credential-free
/// `NetworkFileLocator` (with a stable representation identity), discovering text
/// sidecar subtitles next to a video, and the opt-in on-device stream-probe
/// measurement. It depends only on the live file-tree `ShareLibraryStore` and the
/// engine prober — never on the catalog — so it is a clean, independently testable
/// boundary. `ShareProvider` delegates here and keeps only playback orchestration.
struct SharePlaybackSourceService: Sendable {
    private let store: ShareLibraryStore
    private let streamProber: NetworkFileStreamProbing?
    private let accountID: String
    private let credentialRevision: CredentialRevision

    init(
        store: ShareLibraryStore,
        streamProber: NetworkFileStreamProbing?,
        accountID: String,
        credentialRevision: CredentialRevision
    ) {
        self.store = store
        self.streamProber = streamProber
        self.accountID = accountID
        self.credentialRevision = credentialRevision
    }

    func networkFileLocator(for relativePath: String) async throws -> NetworkFileLocator {
        let entry = try await store.stat(relativePath: relativePath)
        guard entry.kind == .file, let size = entry.size else {
            throw MediaTransportError.protocolViolation(
                reason: "network file lacks a stable size"
            )
        }
        // Prefer a strong ETag as the representation identity when the transport
        // provides one (WebDAV): it lets the byte source revalidate every read
        // with If-Match. Fall back to modification time (SMB, which has no
        // ETag). A file with neither has no way to detect mid-playback change.
        let identity: RemoteFileIdentity
        if let strongETag = entry.strongETag {
            identity = try RemoteFileIdentity(kind: .strongETag, value: strongETag)
        } else if let modifiedAt = entry.modifiedAt {
            identity = try RemoteFileIdentity(kind: .modificationTime, modifiedAt: modifiedAt)
        } else {
            throw MediaTransportError.protocolViolation(
                reason: "network file lacks a stable identity (no strong ETag or modification time)"
            )
        }
        let representation = try RemoteFileRepresentation(
            size: size,
            identity: identity,
            consistency: .changeDetecting
        )
        return try NetworkFileLocator(
            accountID: accountID,
            sourceID: accountID,
            credentialRevision: credentialRevision,
            relativePath: relativePath,
            representation: representation,
            formatHint: MediaFormatHint(
                container: (relativePath as NSString).pathExtension,
                mimeType: entry.mimeType
            )
        )
    }

    /// Finds text sidecar subtitles for a video by listing its directory (and a
    /// sibling `Subs`/`Subtitles` folder) and matching files by stem, then
    /// materialises each to a local `file://` temp so the player's overlay — which
    /// fetches over HTTP/`file://`, never `smb://` — can read them. Reads are
    /// serial (the SMB session is single-connection) and lazy-small (sidecars are
    /// tiny). Cleans up its temp dir on player teardown is handled by the OS temp
    /// reaper; files are namespaced per item so replays reuse them within a run.
    func discoverSidecarSubtitles(forVideoRelPath relPath: String) async throws -> [MediaTrack] {
        let dir = (relPath as NSString).deletingLastPathComponent
        let videoStem = ShareMediaParser.videoStem((relPath as NSString).lastPathComponent)

        // Gather candidate (directory, entry, isDedicatedSubsFolder) triples from the
        // video's own folder and any sibling Subs/Subtitles folder. On a
        // case-insensitive share (Windows/NTFS/exFAT/macOS-hosted SMB) "Subs" and
        // "subs" resolve to the same folder, so dedup the probed candidates by a
        // lowercased (dir, name) key to avoid surfacing every sidecar 2-4×.
        var candidates: [(dir: String, name: String, dedicated: Bool)] = []
        var seenCandidateKeys = Set<String>()
        let ownDir = dir
        let subFolderNames = ["Subs", "Subtitles", "subs", "subtitles"]
        let subDirs = subFolderNames.map { sub in dir.isEmpty ? sub : "\(dir)/\(sub)" }
        for (listDir, dedicated) in [(ownDir, false)] + subDirs.map({ ($0, true) }) {
            guard let entries = try? await store.rawEntries(inDirectory: listDir) else { continue }
            for entry in entries where entry.kind != .directory && ShareMediaParser.isSubtitleFile(entry.name) {
                let key = "\(listDir.lowercased())/\(entry.name.lowercased())"
                guard seenCandidateKeys.insert(key).inserted else { continue }
                candidates.append((listDir, entry.name, dedicated))
            }
        }
        guard !candidates.isEmpty else { return [] }

        var tracks: [MediaTrack] = []
        var nextID = 5_000
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-sidecars", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        for (candidateDir, name, dedicated) in candidates {
            guard let sidecar = ShareMediaParser.parseSidecar(name) else { continue }
            guard Self.sidecarMatchesVideo(sidecarStem: sidecar.stem, videoStem: videoStem, dedicatedFolder: dedicated) else { continue }

            let relSidecar = candidateDir.isEmpty ? name : "\(candidateDir)/\(name)"
            guard let data = try? await store.readFile(relSidecar), !data.isEmpty else { continue }
            // `.magnitude` (not `abs`) so `Int.min` can't trap; hex keeps it short.
            let stableKey = String(relSidecar.hashValue.magnitude, radix: 16)
            let localURL = tempDir.appendingPathComponent("\(stableKey)-\(name)")
            do {
                try data.write(to: localURL, options: .atomic)
            } catch {
                continue
            }
            let language = sidecar.language
            let langName = language.flatMap { SubtitleLanguageCatalog.displayName(forCode: $0) }
            var title = langName ?? language ?? "Subtitle"
            if sidecar.isForced { title += " (Forced)" }
            if sidecar.isSDH { title += " (SDH)" }
            tracks.append(MediaTrack(
                id: nextID,
                kind: .subtitle,
                displayTitle: title,
                language: language,
                codec: sidecar.ext,
                isForced: sidecar.isForced,
                isHearingImpaired: sidecar.isSDH,
                deliverySource: .localFile(localURL),
                isImageBasedSubtitle: false,
                isExternal: true
            ))
            nextID += 1
        }
        return tracks
    }

    /// Whether a sidecar's parsed stem belongs to the video with `videoStem`.
    ///
    /// In the video's **own** directory we require an *exact* stem match — a
    /// prefix relaxation there cross-attaches sibling episodes with non-zero-padded
    /// numbering (`Show.S01E1.srt` would prefix-match `Show.S01E10.mkv`) and movie
    /// siblings (`Batman` vs `Batman Begins`). In a **dedicated** `Subs/Subtitles`
    /// folder — conventionally holding a single title's subs — we allow a prefix
    /// match, but only at a separator boundary so `E1` still can't match `E10`.
    static func sidecarMatchesVideo(sidecarStem: String, videoStem: String, dedicatedFolder: Bool) -> Bool {
        if sidecarStem == videoStem { return true }
        guard dedicatedFolder else { return false }
        return isPrefixAtBoundary(sidecarStem, of: videoStem)
            || isPrefixAtBoundary(videoStem, of: sidecarStem)
    }

    /// Whether `prefix` is a prefix of `whole` ending at a separator boundary
    /// (the next character is `.`, space, `-`, `_`), so `E1` can't prefix `E10`.
    private static func isPrefixAtBoundary(_ prefix: String, of whole: String) -> Bool {
        guard prefix.count < whole.count, whole.hasPrefix(prefix) else { return false }
        let nextIndex = whole.index(whole.startIndex, offsetBy: prefix.count)
        let next = whole[nextIndex]
        return next == "." || next == " " || next == "-" || next == "_"
    }

    /// Opt-in on-device timing measurement (env `PLZXPROBE=1`): probe this item's
    /// file headers over SMB and log elapsed time + facts, so we can validate the
    /// probe is fast enough for the browse-time metadata feature before building the
    /// full pipeline. Fire-and-forget; never blocks item resolution.
    func measureStreamProbeIfEnabled(itemID: String) {
        guard ProcessInfo.processInfo.environment["PLZXPROBE"] == "1",
              let prober = streamProber else { return }
        Task.detached(priority: .utility) {
            // Record the browse, let the user settle, then probe ONLY if still idle —
            // so probing never competes with active navigation. One in-flight at a
            // time, spaced apart, capped per launch. (A naive fire-per-item version
            // stormed the NAS and, because the probe blocks a thread, froze the UI.)
            await ProbeMeasurementGate.shared.noteActivity()
            try? await Task.sleep(for: .seconds(4))
            guard await ProbeMeasurementGate.shared.tryStartIfIdle(idleFor: 4) else { return }
            defer { Task { await ProbeMeasurementGate.shared.finish() } }
            guard let relPath = await self.store.path(forItemID: itemID) else { return }
            let ext = (relPath as NSString).pathExtension.lowercased()
            let videoExts: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "webm"]
            guard videoExts.contains(ext),
                  let locator = try? await self.networkFileLocator(for: relPath) else { return }
            let name = (relPath as NSString).lastPathComponent
            let start = Date()
            let facts = await prober.probe(locator: locator)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let f = facts {
                HandoffDiagnostics.emit("PROBE ok file=\(name) container=\(ext) elapsed=\(ms)ms range=\(f.videoRangeType ?? "-") res=\(f.videoWidth ?? 0)x\(f.videoHeight ?? 0) vcodec=\(f.videoCodec ?? "-") acodec=\(f.audioCodec ?? "-") ch=\(f.audioChannels ?? 0) atmos=\(f.audioIsAtmos) dur=\(Int(f.durationSeconds ?? 0))s")
            } else {
                HandoffDiagnostics.emit("PROBE FAILED file=\(name) container=\(ext) elapsed=\(ms)ms")
            }
        }
    }
}

/// Serializes the opt-in stream-probe MEASUREMENT to ONE probe at a time and caps the
/// total per launch. A naive fire-per-item version stormed the NAS and — because the
/// probe blocks a thread — exhausted the Swift concurrency pool, stalling artwork and
/// enrichment. This gate makes the measurement safe: browsing a whole folder still
/// runs at most one probe at a time, and never more than `maxTotal` overall.
private actor ProbeMeasurementGate {
    static let shared = ProbeMeasurementGate()
    private var inFlight = false
    private var completed = 0
    private var lastStart = Date.distantPast
    private var lastActivity = Date.distantPast
    private let maxTotal = 12
    /// Minimum gap between probe STARTS.
    private let minInterval: TimeInterval = 6

    /// Record that the user just did something (opened/browsed an item), so probing
    /// can hold off until they've paused.
    func noteActivity() { lastActivity = Date() }

    /// Only start a probe when the user has been IDLE for `idleFor` seconds (no
    /// browsing), so probing never competes with active navigation.
    func tryStartIfIdle(idleFor: TimeInterval) -> Bool {
        let now = Date()
        guard !inFlight, completed < maxTotal,
              now.timeIntervalSince(lastActivity) >= idleFor,
              now.timeIntervalSince(lastStart) >= minInterval else { return false }
        inFlight = true
        lastStart = now
        return true
    }

    func finish() {
        inFlight = false
        completed += 1
    }
}
