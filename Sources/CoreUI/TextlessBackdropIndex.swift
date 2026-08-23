import Foundation

/// The small on-disk record of which shows have textless wide art.
///
/// This exists for one reason: **the answer has to be there on the first frame.**
///
/// The router already remembers what it resolved, in ``MetadataDiskCache``, and
/// remembers its misses too. But reading it is `async` — an actor hop and a lazy
/// file load — so the reply cannot arrive before the row's first screenful has
/// already rendered. Those cards then painted the server's titled art and
/// memoized "keep the logo", and because a card is pinned once it has painted,
/// they stayed wrong for the rest of the session. They corrected only when
/// scrolling far enough tore them down and rebuilt them, which is why the fault
/// looked intermittent and self-healing rather than like a bug.
///
/// So this keeps a second, deliberately tiny copy of just the answer, in a form
/// that can be read **synchronously** while a view body runs.
///
/// It is a cache, not a source of truth: it lives in Caches (the OS may delete
/// it), entries expire, and losing it costs one launch of re-resolving. That is
/// what lets it skip the locking, budgeting and atomic-write machinery a real
/// store would need.
@MainActor
public final class TextlessBackdropIndex {
    public static let sharedIndex = TextlessBackdropIndex()

    /// Answers older than this are re-resolved. Artwork does change — a show with
    /// no textless backdrop today may get one — and a permanent "none" would keep
    /// a logo off forever on the strength of one lookup.
    private static let maximumAge: TimeInterval = 14 * 24 * 60 * 60
    /// Enough for a large Continue Watching history and still only a few KB, which
    /// is what keeps the synchronous read cheap.
    private static let maximumEntries = 400

    private struct Entry: Codable {
        /// `nil` records a conclusive "there is none", which is the whole point of
        /// the file — it is what lets a logo be suppressed on evidence rather than
        /// on a genre guess.
        var url: String?
        var stored: Date
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private var entries: [String: Entry] = [:]
    private var loaded = false
    /// Set when the in-memory map has changes not yet written. The write is
    /// coalesced to the end of the runloop turn so a row that resolves twenty
    /// shows at once writes once, not twenty times.
    private var needsWrite = false

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = directory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("plozz-textless-backdrops", isDirectory: true)
        self.fileURL = base.appendingPathComponent("index.json", isDirectory: false)
    }

    /// Last session's answers, as the store's own vocabulary.
    func load() -> [String: TextlessBackdropStore.Outcome] {
        loadIfNeeded()
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        return entries.reduce(into: [:]) { result, element in
            let (key, entry) = element
            guard entry.stored > cutoff else { return }
            if let raw = entry.url {
                guard let url = URL(string: raw) else { return }
                result[key] = .available(url)
            } else {
                result[key] = TextlessBackdropStore.Outcome.none
            }
        }
    }

    func save(_ outcome: TextlessBackdropStore.Outcome, for key: String) {
        loadIfNeeded()
        switch outcome {
        case .available(let url): entries[key] = Entry(url: url.absoluteString, stored: Date())
        case .none: entries[key] = Entry(url: nil, stored: Date())
        }
        scheduleWrite()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func scheduleWrite() {
        guard !needsWrite else { return }
        needsWrite = true
        Task { @MainActor [weak self] in
            self?.writeNow()
        }
    }

    private func writeNow() {
        needsWrite = false
        // Oldest first, so a long history sheds the answers least likely to be
        // needed rather than whatever the dictionary happened to order last.
        if entries.count > Self.maximumEntries {
            let keep = entries.sorted { $0.value.stored > $1.value.stored }
                .prefix(Self.maximumEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Writes any pending changes immediately. For tests, which cannot wait on a
    /// coalesced runloop hop.
    func flushForTesting() {
        writeNow()
    }
}
