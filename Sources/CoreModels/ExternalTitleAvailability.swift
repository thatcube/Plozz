import Foundation

/// One region-scoped release event for a title the viewer may not own.
public struct TitleReleaseEvent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case premiere
        case theatricalLimited
        case theatrical
        case digital
        case physical
        case television
    }

    public var kind: Kind
    /// A civil release date in ``regionCode``. It is not a moment to convert
    /// across time zones.
    public var date: Date
    public var regionCode: String
    public var certification: String?
    public var note: String?

    public init(
        kind: Kind,
        date: Date,
        regionCode: String,
        certification: String? = nil,
        note: String? = nil
    ) {
        self.kind = kind
        self.date = date
        self.regionCode = regionCode
        self.certification = certification
        self.note = note
    }
}

/// A current, region-scoped place to watch a title.
///
/// TMDb's endpoint is powered by JustWatch and reports current offers only; it
/// cannot support future copy such as "Streaming August 3."
public struct TitleWatchOffer: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case subscription
        case free
        case ads
        case rent
        case buy
    }

    public var providerID: Int
    public var providerName: String
    public var kind: Kind
    public var regionCode: String
    public var logoURL: URL?

    public init(
        providerID: Int,
        providerName: String,
        kind: Kind,
        regionCode: String,
        logoURL: URL? = nil
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.kind = kind
        self.regionCode = regionCode
        self.logoURL = logoURL
    }

    public var id: String { "\(regionCode)|\(kind.rawValue)|\(providerID)" }
}

/// Release and current consumer-availability facts for an external title.
///
/// Deliberately separate from `MediaAvailabilityStatus`, which means whether
/// Seerr has put media in the viewer's own library.
public struct ExternalTitleAvailability: Codable, Hashable, Sendable {
    public var regionCode: String
    public var releaseEvents: [TitleReleaseEvent]
    public var watchOffers: [TitleWatchOffer]
    /// URL TMDb/JustWatch supplies for provider attribution/deep-link context.
    public var watchProvidersURL: URL?

    public init(
        regionCode: String,
        releaseEvents: [TitleReleaseEvent] = [],
        watchOffers: [TitleWatchOffer] = [],
        watchProvidersURL: URL? = nil
    ) {
        self.regionCode = regionCode
        self.releaseEvents = releaseEvents
        self.watchOffers = watchOffers
        self.watchProvidersURL = watchProvidersURL
    }

    public var isEmpty: Bool { releaseEvents.isEmpty && watchOffers.isEmpty }

    /// One honest, glanceable hero line — deliberately about TIME, not place.
    ///
    /// The hero has room for a single fact, and for someone running their own
    /// server the useful one is "when can this be mine": a date it reaches digital,
    /// a premiere still ahead, or that it is in cinemas only and so cannot be
    /// requested yet. Which streaming services happen to carry a title is a
    /// different question, and for this audience usually not the one being asked —
    /// they are mostly here to get it into their library, not to be told they could
    /// subscribe to Philo. It stays available in "Release & Availability" below,
    /// with the service marks, for the minority who do want it.
    ///
    /// Facts with no future in them are also dropped: "available digitally since
    /// 2019" and "premiered 2018" restate the year already printed beside the
    /// title. Whether Plozz can Play or Request is the action row's job, not this
    /// line's.
    public func primaryLine(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> LocalizedStringResource? {
        let startToday = calendar.startOfDay(for: now)
        let hasReleasedTheatrically = releaseEvents.contains {
            calendar.startOfDay(for: $0.date) < startToday
                && ($0.kind == .theatrical
                    || $0.kind == .theatricalLimited
                    || $0.kind == .premiere)
        }
        let future = releaseEvents
            .filter { calendar.startOfDay(for: $0.date) >= startToday }
            .sorted { $0.date < $1.date }
        if let next = future.first {
            switch next.kind {
            case .theatrical, .theatricalLimited:
                return "In theaters \(next.date, format: .dateTime.month(.abbreviated).day())"
            case .premiere:
                return "Premieres \(next.date, format: .dateTime.month(.abbreviated).day())"
            case .digital:
                if hasReleasedTheatrically {
                    return "In theaters · Available digitally \(next.date, format: .dateTime.month(.abbreviated).day())"
                }
                return "Available digitally \(next.date, format: .dateTime.month(.abbreviated).day())"
            case .television:
                return "Premieres \(next.date, format: .dateTime.month(.abbreviated).day())"
            case .physical:
                return "Physical \(next.date, format: .dateTime.month(.abbreviated).day())"
            }
        }

        // Released in cinemas with no digital date yet. Kept because it is the one
        // PAST fact that still changes what the viewer does: it means a request
        // cannot be filled yet, however many services list the title.
        //
        // Contradicted by EVIDENCE rather than by a clock. An older film often has
        // no digital release event recorded at all — "Intruders" (2011) has none —
        // and reading that silence as "still in cinemas" is how a fourteen-year-old
        // film came to claim it. But if the source lists anywhere at all to stream,
        // rent or buy it, then it demonstrably left cinemas, whatever the release
        // events do or don't say. A title with no offers listed keeps the claim, so
        // a genuinely cinema-only release still reports correctly and no arbitrary
        // expiry is introduced.
        let past = releaseEvents.sorted { $0.date > $1.date }
        if watchOffers.isEmpty,
           past.first(where: { $0.kind == .digital }) == nil,
           past.contains(where: {
               $0.kind == .theatrical
                   || $0.kind == .theatricalLimited
                   || $0.kind == .premiere
           }) {
            return "Only in theaters"
        }
        // Anything else is history, not news: that a 2018 show has been available
        // digitally for years, or premiered in a year already printed beside the
        // title, tells a self-hoster nothing they can act on. Where it streams now
        // lives in "Release & Availability" below, where someone who wants it can
        // find it and everyone else is not made to read it.
        return nil
    }

    /// Prefer a service's direct offer over marketplace channel add-ons. TMDb/
    /// JustWatch can return both `Max` and `HBO Max Amazon Channel`; API ordering
    /// is not a UX priority and briefly made the hero advertise the reseller
    /// instead of the service most viewers recognize.
    ///
    /// The full channel name is retained when it is the only offer — stripping
    /// "Amazon Channel" there would falsely claim a direct Max subscription works.
    /// The underlying service, with the storefront it is billed through removed.
    ///
    /// "Starz", "Starz Apple TV Channel", "Starz Roku Premium Channel" and "Starz
    /// Amazon Channel" are one service sold four ways. Listing them separately —
    /// which is what the source does — turns a short answer into a wall of
    /// near-duplicates and buries the services that are genuinely different.
    public static func collapsedServiceName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [
            // Longest first: "Free with Ads" must not be left as a "Free" stub.
            "Free with Ads",
            "with Ads",
            "Apple TV Channel",
            "Amazon Channel",
            "Roku Premium Channel",
        ] where trimmed.count > suffix.count
            && trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            return displayProviderName(
                String(trimmed.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return displayProviderName(trimmed)
    }


    /// TMDb/JustWatch still returns the 2023–2025 direct-service brand `Max` in
    /// some regions. The consumer-facing service renamed back to HBO Max; only
    /// normalize the exact direct-service token so reseller names keep their
    /// meaningful qualifier.
    private static func displayProviderName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Max") == .orderedSame
            ? "HBO Max"
            : name
    }

}
