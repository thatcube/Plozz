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

    /// One honest, glanceable hero line. Release state and current provider
    /// availability are facts; whether Plozz can Play or Request is shown
    /// separately by its action row.
    public func primaryLine(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> LocalizedStringResource? {
        if let streaming = preferredOffer(for: [.subscription, .free, .ads]) {
            let provider = Self.displayProviderName(streaming.providerName)
            return "Streaming on \(provider)"
        }
        if let transactional = preferredOffer(for: [.rent, .buy]) {
            let provider = Self.displayProviderName(
                transactional.providerName
            )
            return "Available digitally on \(provider)"
        }

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

        let past = releaseEvents.sorted { $0.date > $1.date }
        if let digital = past.first(where: { $0.kind == .digital }) {
            return "Available digitally since \(digital.date, format: .dateTime.month(.abbreviated).day().year())"
        }
        if past.contains(where: {
            $0.kind == .theatrical
                || $0.kind == .theatricalLimited
                || $0.kind == .premiere
        }) {
            return "Only in theaters"
        }
        if let television = past.first(where: { $0.kind == .television }) {
            return "Premiered \(television.date, format: .dateTime.month(.abbreviated).day().year())"
        }
        return nil
    }

    /// Prefer a service's direct offer over marketplace channel add-ons. TMDb/
    /// JustWatch can return both `Max` and `HBO Max Amazon Channel`; API ordering
    /// is not a UX priority and briefly made the hero advertise the reseller
    /// instead of the service most viewers recognize.
    ///
    /// The full channel name is retained when it is the only offer — stripping
    /// "Amazon Channel" there would falsely claim a direct Max subscription works.
    private func preferredOffer(
        for kinds: Set<TitleWatchOffer.Kind>
    ) -> TitleWatchOffer? {
        watchOffers
            .enumerated()
            .filter { kinds.contains($0.element.kind) }
            .min { lhs, rhs in
                let left = Self.isChannelAddOn(lhs.element.providerName)
                let right = Self.isChannelAddOn(rhs.element.providerName)
                if left != right { return !left }
                return lhs.offset < rhs.offset
            }?
            .element
    }

    private static func isChannelAddOn(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("amazon channel")
            || normalized.contains("apple tv channel")
            || normalized.contains("roku premium channel")
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
