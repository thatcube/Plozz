#if canImport(Foundation)
import Foundation
import CoreModels

/// Somewhere a person's biography can be fetched from.
///
/// Deliberately a small protocol with several implementations rather than one
/// concrete service: a person page must never be hostage to a single provider
/// being reachable, keyed, or willing. The viewer's own servers answer first and
/// cost nothing; these are consulted only when every server has come back empty.
public protocol PersonBiographyProvider: Sendable {
    /// Which source this is, for provenance.
    var id: MetadataSource { get }

    /// A biography for `name`, or `nil` when this provider can't confidently
    /// identify the person. Returning `nil` is always preferable to returning
    /// the wrong person's life story.
    ///
    /// - Parameters:
    ///   - name: the person's name as the media server spelled it.
    ///   - role: the provider-native role kind (`Actor`, `Director`, …) when
    ///     known, used to disambiguate people who share a name.
    func biography(for name: String, role: String?) async -> String?
}

/// Biographies from Wikipedia.
///
/// Chosen as the first fallback beyond the viewer's own servers because it needs
/// no API key, no account and no rate-limit registration, its text is openly
/// licensed, and its coverage of *people* is broader than any film database's.
/// That keeps the person page from resting on a single commercial provider.
///
/// One request per lookup: a search generator returns the top candidates *with*
/// their intro extracts and short descriptions, so ranking, disambiguation and
/// text retrieval all resolve together.
public struct WikipediaPersonBiographyProvider: PersonBiographyProvider {
    public let id = MetadataSource.wikipedia

    /// Language edition to read. English has by far the widest coverage of
    /// screen credits, and the biography is prose rather than UI copy.
    private let language: String
    private let maximumCandidates: Int
    /// Trimmed to a couple of paragraphs: this sits in a header beside a
    /// headshot, not in an encyclopaedia.
    private let maximumLength: Int

    public init(language: String = "en", maximumCandidates: Int = 5, maximumLength: Int = 1200) {
        self.language = language
        self.maximumCandidates = maximumCandidates
        self.maximumLength = maximumLength
    }

    public func biography(for name: String, role: String?) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = searchURL(for: trimmed) else { return nil }
        let started = Date()
        guard let response = await MetadataHTTP.get(SearchResponse.self, url: url) else {
            PersonDiagnostics.emit(
                "wiki.http name=\(trimmed) result=FAILED ms=\(Int(Date().timeIntervalSince(started) * 1000))"
            )
            return nil
        }
        let httpMS = Int(Date().timeIntervalSince(started) * 1000)

        // Best-ranked first. `index` is the search rank; where it's absent the
        // array order already is the ranking, so a stable sort preserves it.
        let candidates = (response.query?.pages ?? [])
            .enumerated()
            .sorted {
                ($0.element.index ?? $0.offset, $0.offset) < ($1.element.index ?? $1.offset, $1.offset)
            }
            .map(\.element)

        for page in candidates {
            guard Self.isPlausiblePerson(page: page, name: trimmed) else { continue }
            guard let extract = page.extract?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !extract.isEmpty
            else { continue }
            PersonDiagnostics.emit(
                "wiki.http name=\(trimmed) result=hit title=\(page.title ?? "?") "
                + "candidates=\(candidates.count) ms=\(httpMS)"
            )
            return Self.trimmed(extract, to: maximumLength)
        }
        // Which half rejected it matters: a namesake guard turning candidates
        // away is a correctness decision, an empty candidate list is a lookup
        // that found nothing at all, and the two need opposite fixes.
        PersonDiagnostics.emit(
            "wiki.http name=\(trimmed) result=REJECTED candidates=\(candidates.count) "
            + "titles=[\(candidates.prefix(4).map { $0.title ?? "?" }.joined(separator: "|"))] "
            + "descs=[\(candidates.prefix(4).map { $0.description ?? "-" }.joined(separator: "|"))] "
            + "ms=\(httpMS)"
        )
        return nil
    }

    private func searchURL(for name: String) -> URL? {
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            // A search *generator* so ranking, the intro text and the short
            // description all arrive together — one round trip per person.
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: name),
            URLQueryItem(name: "gsrlimit", value: String(maximumCandidates)),
            URLQueryItem(name: "prop", value: "extracts|description"),
            // Lead section only, as plain text: the full article is megabytes and
            // the wikitext would need rendering.
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exlimit", value: String(maximumCandidates)),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]
        return components?.url
    }

    /// Whether a search hit is plausibly *this* person, rather than a namesake or
    /// an unrelated article the search happened to rank.
    ///
    /// Both halves matter, and the occupation check is the load-bearing one:
    /// searching "Richard Armitage" finds an actor, a US Deputy Secretary of
    /// State and an 18th-century MP. Showing a viewer the diplomat's biography
    /// under the actor's headshot is worse than showing none, so a hit is only
    /// accepted when its short description names a screen occupation.
    static func isPlausiblePerson(page: SearchResponse.Page, name: String) -> Bool {
        let title = page.title ?? ""
        guard !title.isEmpty else { return false }
        // Every part of the name must appear as a whole word in the title.
        //
        // Token-wise rather than as a substring, because Wikipedia may hold a
        // name in a different order than the media server does — a server's
        // "Kayano Ai" is Wikipedia's "Ai Kayano", and a substring test rejects
        // every Japanese voice actor on that basis alone. Whole words rather
        // than a loose contains, so a search for "Martin Freeman" cannot settle
        // on "Joe Freeman", who is also an English actor and so passes the
        // occupation check on his own merits.
        // The title's tokens, minus any parenthetical qualifier Wikipedia adds to
        // disambiguate ("Richard Armitage (actor)").
        let titleTokens = tokens(of: title.replacingOccurrences(
            of: "\\([^)]*\\)", with: " ", options: .regularExpression
        ))
        let nameTokens = tokens(of: name)
        guard !nameTokens.isEmpty else { return false }
        // Every requested token must appear, AND the title may not carry extra
        // ones. Containment alone accepts a longer, different name: "Michael B.
        // Jordan" holds both tokens of "Michael Jordan" and is genuinely an actor,
        // so the occupation check clears it too. Comparing the sets both ways is
        // what separates a qualifier from a different person.
        guard Set(nameTokens) == Set(titleTokens) else { return false }

        let description = (page.description ?? "").lowercased()
        guard !description.isEmpty else { return false }
        // A disambiguation page carries no biography, only links. Wikidata
        // describes those as "Topics referred to by the same term" rather than
        // using the word "disambiguation", so both spellings are rejected.
        guard !description.contains("disambiguation"),
              !description.contains("referred to by the same term")
        else { return false }
        return screenOccupations.contains { description.contains($0) }
    }

    /// Occupations that put someone on screen or behind a production. Matched
    /// against Wikipedia's one-line description ("English actor and producer").
    private static let screenOccupations = [
        "actor", "actress", "voice art", "seiyu", "seiyū",
        "director", "filmmaker", "screenwriter", "producer",
        "comedian", "singer", "musician", "presenter", "television"
    ]

    /// Lowercased, accent-folded words, split on anything that isn't a letter or
    /// number — so parenthetical qualifiers ("(actor)") and punctuation
    /// ("Kayano, Ai") fall out on their own.
    private static func tokens(of value: String) -> [String] {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Clips to a sentence boundary near the limit so the text never ends
    /// mid-word, and only adds an ellipsis when something was actually removed.
    static func trimmed(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let clipped = String(text.prefix(limit))
        if let lastStop = clipped.lastIndex(where: { ".!?".contains($0) }) {
            let sentence = String(clipped[...lastStop])
            // Guard against a lone early sentence leaving almost nothing.
            if sentence.count > limit / 2 { return sentence }
        }
        return clipped.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    struct SearchResponse: Decodable {
        struct Page: Decodable {
            let title: String?
            let extract: String?
            let description: String?
            /// Search rank; `formatversion=2` returns pages as an array but keeps
            /// this so the original ordering survives.
            let index: Int?
        }
        struct Query: Decodable {
            /// Ordered, because the order *is* the search ranking.
            let pages: [Page]?

            /// `formatversion=2` returns `pages` as an array; older versions
            /// return a dictionary keyed by page id. Accept both, so tuning the
            /// request later can't silently break decoding.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let list = try? container.decode([Page].self, forKey: .pages) {
                    pages = list
                } else if let map = try? container.decode([String: Page].self, forKey: .pages) {
                    pages = map.values.sorted { ($0.index ?? .max) < ($1.index ?? .max) }
                } else {
                    pages = nil
                }
            }

            private enum CodingKeys: String, CodingKey { case pages }
        }
        let query: Query?
    }
}
#endif
