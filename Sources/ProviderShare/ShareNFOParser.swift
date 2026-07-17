import Foundation

/// One external id parsed from an NFO's `<uniqueid>` (or a direct `<imdbid>` /
/// `<tmdbid>` / `<tvdbid>` element), before namespace/value normalization.
struct ParsedNFOID: Sendable, Equatable {
    /// Raw `type` attribute (or implied namespace for a direct element),
    /// lowercased but NOT yet alias-normalized.
    var rawNamespace: String
    var rawValue: String
    var isDefault: Bool
}

/// One rating entry. Kept even when `source` doesn't map to a known
/// `RatingSource` (and even when `value`/`max` can't be normalized) so it can be
/// losslessly retained in the persisted local payload — see the field
/// normalization table in the Step 3 plan.
struct ParsedNFORating: Sendable, Equatable, Codable {
    var source: String
    var value: Double
    var max: Double
    var votes: Int?
    var isDefault: Bool
}

/// The Kodi/Jellyfin NFO root the document declared.
enum NFORootKind: String, Sendable, Equatable {
    case movie
    case tvshow
    case episodedetails
}

/// A normalized, bounded parse of one NFO document. Parsing performs no storage
/// or network work — see `ShareNFOParser`.
struct ParsedNFO: Sendable, Equatable {
    var root: NFORootKind
    var title: String?
    var originalTitle: String?
    var sortTitle: String?
    var year: Int?
    var taglines: [String] = []
    var plot: String?
    var outline: String?
    var genres: [String] = []
    var studios: [String] = []
    var tags: [String] = []
    /// Seconds, normalized from a bounded positive minute value or an `HH:MM[:SS]`
    /// duration form.
    var runtimeSeconds: TimeInterval?
    /// Normalized `yyyy-MM-dd` local-date string, or nil when absent/invalid.
    var premiered: String?
    /// Normalized `yyyy-MM-dd` local-date string, or nil when absent/invalid.
    var aired: String?
    var season: Int?
    var episode: Int?
    var ratings: [ParsedNFORating] = []
    var ids: [ParsedNFOID] = []

    /// Trimmed `plot` wins; `outline` fills only when plot is absent/blank.
    var overview: String? {
        if let plot, !plot.isEmpty { return plot }
        if let outline, !outline.isEmpty { return outline }
        return nil
    }
}

enum NFOParseOutcome: Sendable, Equatable {
    case parsed(ParsedNFO)
    /// Not a recognized/well-formed Kodi/Jellyfin NFO document.
    case malformed
    /// Exceeded `ShareNFOParser.maxBytes` before parsing began.
    case oversized
}

/// Bounded, tolerant, safe parser for Kodi/Jellyfin `movie` / `tvshow` /
/// `episodedetails` NFO sidecars, built on Foundation's `XMLParser` (streaming
/// SAX-style — memory tracks document size, not a multiplied DOM tree). Mirrors
/// the security posture of `PropfindXMLParser`: external entities are never
/// resolved, and every bound (byte size, accumulated text, repeated-list counts)
/// is a hard cap rather than a silent truncation surprise.
///
/// Tolerance: element/attribute names are matched case-insensitively, unknown
/// elements/namespaces are ignored (not a parse failure), and an individual
/// invalid field is simply omitted rather than failing the whole document —
/// callers apply field-level validation on top of the raw parsed strings before
/// treating a value as usable.
enum ShareNFOParser {
    /// Hard maximum accepted document size. Exactly this many bytes still parses;
    /// anything larger is rejected before parsing begins.
    static let maxBytes = 1_048_576
    /// Per-element accumulated text cap — bounds a single legal-size document from
    /// building an unbounded string via pathological repeated character data.
    static let maxElementTextLength = 65_536
    /// Cap on repeated-list-producing elements (`genre`, `studio`, `tag`,
    /// `uniqueid`, nested `rating`) so a legal-size document can't create an
    /// unbounded intermediate collection.
    static let maxListEntries = 512

    /// Parser-only semantic version. Advanced (v1 -> v2) when the parse RULES change
    /// (root-gated episode-only fields, strict impossible-date rejection) so an
    /// already-indexed catalog rereads each existing NFO exactly once under the
    /// corrected rules. Persisted per-sidecar in `local_metadata_files.parser_version`
    /// and INDEPENDENT of the classifier, local-inventory, local-materialization, and
    /// external enrichment versions — a bump forces no external work.
    static let parserVersion = 2

    static func parse(_ data: Data) -> NFOParseOutcome {
        guard data.count <= maxBytes else { return .oversized }
        let delegate = NFODelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        // Belt-and-suspenders: XMLParser already defaults to never resolving
        // external entities, but this parser refuses explicitly on both axes (see
        // `PropfindXMLParser`) — no DTD/include/remote resource is ever fetched.
        parser.shouldResolveExternalEntities = false
        let succeeded = parser.parse()
        guard succeeded, !delegate.limitExceeded, let root = delegate.rootKind else {
            return .malformed
        }
        return .parsed(delegate.makeResult(root: root))
    }
}

/// SAX-style delegate accumulating one `ParsedNFO`. Not `Sendable`/shared — a
/// fresh instance is created per parse and only touched from the (synchronous)
/// `XMLParser.parse()` call on the calling thread.
private final class NFODelegate: NSObject, XMLParserDelegate {
    private(set) var rootKind: NFORootKind?
    private(set) var limitExceeded = false

    private var elementStack: [String] = []
    private var textBuffer = ""

    private var title: String?
    private var originalTitle: String?
    private var sortTitle: String?
    private var year: Int?
    private var taglines: [String] = []
    private var plot: String?
    private var outline: String?
    private var genres: [String] = []
    private var studios: [String] = []
    private var tags: [String] = []
    private var runtimeSeconds: TimeInterval?
    private var premiered: String?
    private var aired: String?
    private var season: Int?
    private var episode: Int?
    private var ratings: [ParsedNFORating] = []
    private var ids: [ParsedNFOID] = []

    // <ratings><rating> nested-block staging.
    private var inRatingsBlock = false
    private var pendingRatingName: String?
    private var pendingRatingMax: Double?
    private var pendingRatingDefault = false
    private var pendingRatingValue: Double?
    private var pendingRatingVotes: Int?

    // <uniqueid> attribute staging (attributes arrive with didStartElement).
    private var pendingIDNamespace: String?
    private var pendingIDDefault = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = Self.localName(elementName).lowercased()
        if elementStack.isEmpty {
            guard let kind = NFORootKind(rawValue: local) else {
                parser.abortParsing()
                return
            }
            rootKind = kind
        }
        elementStack.append(local)
        textBuffer = ""

        switch local {
        case "ratings":
            inRatingsBlock = true
        case "rating":
            guard elementStack.dropLast().last == "ratings" else { break }
            pendingRatingName = attributeDict.first { $0.key.caseInsensitiveCompare("name") == .orderedSame }?.value
            pendingRatingMax = attributeDict.first { $0.key.caseInsensitiveCompare("max") == .orderedSame }
                .flatMap { Double($0.value) }
            pendingRatingDefault = attributeDict.first { $0.key.caseInsensitiveCompare("default") == .orderedSame }?
                .value.lowercased() == "true"
            pendingRatingValue = nil
            pendingRatingVotes = nil
        case "uniqueid":
            pendingIDNamespace = attributeDict.first { $0.key.caseInsensitiveCompare("type") == .orderedSame }?.value
            pendingIDDefault = attributeDict.first { $0.key.caseInsensitiveCompare("default") == .orderedSame }?
                .value.lowercased() == "true"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard textBuffer.count < ShareNFOParser.maxElementTextLength else { return }
        let remaining = ShareNFOParser.maxElementTextLength - textBuffer.count
        textBuffer += remaining >= string.count ? string : String(string.prefix(remaining))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = Self.localName(elementName).lowercased()
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""
        let parent = elementStack.dropLast().last

        switch local {
        case "title":
            if parent == rootKind?.rawValue, !text.isEmpty { title = text }
        case "originaltitle":
            if parent == rootKind?.rawValue, !text.isEmpty { originalTitle = text }
        case "sorttitle":
            if parent == rootKind?.rawValue, !text.isEmpty { sortTitle = text }
        case "year":
            if let y = Int(text), (1870...2999).contains(y) { year = y }
        case "tagline":
            appendBounded(&taglines, text)
        case "plot":
            if parent == rootKind?.rawValue, !text.isEmpty { plot = text }
        case "outline":
            if parent == rootKind?.rawValue, !text.isEmpty { outline = text }
        case "genre":
            appendBounded(&genres, text)
        case "studio":
            appendBounded(&studios, text)
        case "tag":
            appendBounded(&tags, text)
        case "runtime":
            if let seconds = Self.parseRuntime(text) { runtimeSeconds = seconds }
        case "premiered":
            if let normalized = Self.normalizeDate(text) { premiered = normalized }
        case "aired":
            if rootKind == .episodedetails, let normalized = Self.normalizeDate(text) { aired = normalized }
        case "season":
            if rootKind == .episodedetails, let s = Int(text), s >= 0 { season = s }
        case "episode":
            if rootKind == .episodedetails, let e = Int(text), e >= 0 { episode = e }
        case "imdbid", "imdb_id":
            if Self.isValidIMDbID(text) { commitID(namespace: "imdb", value: text, isDefault: false) }
        case "tmdbid":
            if Self.isValidNumericID(text) { commitID(namespace: "tmdb", value: text, isDefault: false) }
        case "tvdbid":
            if Self.isValidNumericID(text) { commitID(namespace: "tvdb", value: text, isDefault: false) }
        case "uniqueid":
            if let namespace = pendingIDNamespace?.lowercased(), !text.isEmpty {
                commitID(namespace: namespace, value: text, isDefault: pendingIDDefault)
            }
            pendingIDNamespace = nil
            pendingIDDefault = false
        case "value":
            if inRatingsBlock, parent == "rating" { pendingRatingValue = Double(text) }
        case "votes":
            if inRatingsBlock, parent == "rating" {
                pendingRatingVotes = Int(text)
            } else if !inRatingsBlock, parent == rootKind?.rawValue, let v = Int(text) {
                pendingScalarVotes = v
            }
        case "rating":
            if parent == "ratings" {
                commitRating()
            } else if parent == rootKind?.rawValue, let v = Double(text) {
                // Bare scalar <rating>8.8</rating> (+ sibling <votes>), common on
                // the movie/tvshow root directly (not nested under <ratings>).
                pendingScalarRatingValue = v
            }
        case "ratings":
            inRatingsBlock = false
        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // Surfaced via `succeeded == false` from `XMLParser.parse()`; nothing to
        // capture here beyond that.
    }

    /// Never resolve external entities — refusing here is defense-in-depth on top
    /// of `shouldResolveExternalEntities = false`.
    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        nil
    }

    // MARK: - Scalar (root-level, non-<ratings>) rating fallback
    //
    // Committed at document end (see `makeResult`) so root `<rating>`/`<votes>`
    // order is tolerated either way.
    private var pendingScalarRatingValue: Double?
    private var pendingScalarVotes: Int?

    // MARK: - Helpers

    private func appendBounded(_ list: inout [String], _ value: String) {
        guard !value.isEmpty, list.count < ShareNFOParser.maxListEntries else { return }
        guard !list.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        list.append(value)
    }

    private func commitID(namespace: String, value: String, isDefault: Bool) {
        guard ids.count < ShareNFOParser.maxListEntries else { return }
        ids.append(ParsedNFOID(rawNamespace: namespace, rawValue: value, isDefault: isDefault))
    }

    private func commitRating() {
        defer {
            pendingRatingName = nil
            pendingRatingMax = nil
            pendingRatingDefault = false
            pendingRatingValue = nil
            pendingRatingVotes = nil
        }
        guard ratings.count < ShareNFOParser.maxListEntries,
              let name = pendingRatingName, !name.isEmpty,
              let value = pendingRatingValue,
              value.isFinite, value >= 0 else { return }
        let max = pendingRatingMax.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 10
        guard value <= max else { return }
        ratings.append(ParsedNFORating(
            source: name,
            value: value,
            max: max,
            votes: pendingRatingVotes,
            isDefault: pendingRatingDefault
        ))
    }

    func makeResult(root: NFORootKind) -> ParsedNFO {
        var result = ParsedNFO(
            root: root,
            title: title,
            originalTitle: originalTitle,
            sortTitle: sortTitle,
            year: year,
            taglines: taglines,
            plot: plot,
            outline: outline,
            genres: genres,
            studios: studios,
            tags: tags,
            runtimeSeconds: runtimeSeconds,
            premiered: premiered,
            aired: aired,
            season: season,
            episode: episode,
            ratings: ratings,
            ids: ids
        )
        // A bare scalar <rating> (no nested <ratings> block) defaults to an
        // "imdb"-style top-level score — Kodi's oldest, still-common convention.
        if result.ratings.isEmpty,
           let value = pendingScalarRatingValue, value.isFinite, value >= 0, value <= 10 {
            result.ratings = [ParsedNFORating(
                source: "imdb", value: value, max: 10, votes: pendingScalarVotes, isDefault: true
            )]
        }
        return result
    }

    private static func localName(_ raw: String) -> String {
        guard let colon = raw.firstIndex(of: ":") else { return raw }
        return String(raw[raw.index(after: colon)...])
    }

    /// Bounded positive minute value, or `HH:MM[:SS]`.
    static func parseRuntime(_ text: String) -> TimeInterval? {
        if let minutes = Double(text), minutes.isFinite, minutes > 0, minutes < 100_000 {
            return minutes * 60
        }
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3,
              let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0..<100_000).contains(hours),
              (0..<60).contains(minutes) else { return nil }
        let seconds: Int
        if parts.count == 3, let s = Int(parts[2]), (0..<60).contains(s) {
            seconds = s
        } else if parts.count == 3 {
            return nil
        } else {
            seconds = 0
        }
        return TimeInterval(hours * 3_600 + minutes * 60 + seconds)
    }

    /// Accepts `yyyy-MM-dd` (Kodi/Jellyfin's convention) and normalizes to the
    /// same form after validating it's a real calendar date.
    static func normalizeDate(_ text: String) -> String? {
        let parts = text.split(separator: "-").map(String.init)
        guard parts.count == 3,
              parts[0].count == 4, let y = Int(parts[0]),
              let m = Int(parts[1]), (1...12).contains(m),
              let d = Int(parts[2]), (1...31).contains(d) else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        // `Calendar` is lenient: `date(from:)` silently ROLLS an impossible date
        // (2023-02-29 -> 2023-03-01, 2024-04-31 -> 2024-05-01) into a valid `Date`
        // rather than failing. Round-trip the produced date back to components and
        // require an exact match so impossible calendar dates are rejected.
        guard let date = calendar.date(from: comps) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == y, roundTrip.month == m, roundTrip.day == d else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func isValidIMDbID(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.hasPrefix("tt"), lower.count > 2 else { return false }
        return lower.dropFirst(2).allSatisfy(\.isNumber)
    }

    static func isValidNumericID(_ text: String) -> Bool {
        guard !text.isEmpty, text.allSatisfy(\.isNumber) else { return false }
        return Int(text).map { $0 > 0 } ?? false
    }
}
