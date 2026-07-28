import Foundation

/// Seerr's request state for one numbered TV season.
public struct MediaSeasonRequestState: Identifiable, Sendable, Equatable {
    public var id: Int { number }
    public let number: Int
    public let title: String  // l10n:content — season title from the media server
    public var status: MediaAvailabilityStatus
    public var requestFailed: Bool

    public init(
        number: Int,
        title: String,  // l10n:content — season title from the media server
        status: MediaAvailabilityStatus,
        requestFailed: Bool = false
    ) {
        self.number = number
        self.title = title
        self.status = status
        self.requestFailed = requestFailed
    }

    public var isRequestable: Bool {
        !requestFailed && (status == .unknown || status == .deleted)
    }

    public var isInFlight: Bool {
        !requestFailed && (status == .pending || status == .processing)
    }

    /// Only missing or in-flight seasons belong in request UI. Available and
    /// partially available seasons remain represented by the real library tabs.
    public var belongsInRequestPicker: Bool {
        requestFailed || isRequestable || isInFlight
    }
}

/// Provider-agnostic request coverage for a movie or series.
public struct MediaRequestAvailability: Sendable, Equatable {
    public var status: MediaAvailabilityStatus
    public var downloadProgress: Double?
    public var seasons: [MediaSeasonRequestState]

    public init(
        status: MediaAvailabilityStatus,
        downloadProgress: Double? = nil,
        seasons: [MediaSeasonRequestState] = []
    ) {
        self.status = status
        self.downloadProgress = downloadProgress
        self.seasons = seasons
    }

    public var requestPickerSeasons: [MediaSeasonRequestState] {
        seasons.filter(\.belongsInRequestPicker)
    }

    public var requestableSeasonNumbers: [Int] {
        seasons.filter(\.isRequestable).map(\.number)
    }

    public var hasSeasonRequestContent: Bool {
        !requestPickerSeasons.isEmpty
    }

    public func markingRequested(_ seasonNumbers: [Int]) -> Self {
        let requested = Set(seasonNumbers)
        var copy = self
        copy.seasons = seasons.map { season in
            guard requested.contains(season.number), season.isRequestable else { return season }
            var updated = season
            updated.status = .pending
            updated.requestFailed = false
            return updated
        }
        return copy
    }

    public func markingAvailable(_ seasonNumbers: [Int]) -> Self {
        let available = Set(seasonNumbers)
        guard !available.isEmpty else { return self }
        var copy = self
        copy.seasons = seasons.map { season in
            guard available.contains(season.number) else { return season }
            var updated = season
            updated.status = .available
            updated.requestFailed = false
            return updated
        }
        return copy
    }
}

/// The result of a one-tap "Request" action (Seerr/Overseerr), in a
/// provider-agnostic shape so `FeatureHome` can surface success + typed failures
/// without importing the Seerr module. `AppShell` maps the concrete
/// `SeerRequestOutcome` onto this (translating failure reasons into user-facing
/// copy, including the acting user's name where relevant).
public struct MediaRequestActionResult: Sendable, Equatable {
    /// The title's resulting availability on success (`.pending` = created,
    /// awaiting approval). `nil` on failure.
    public var status: MediaAvailabilityStatus?
    /// A short, user-facing failure title (e.g. "Request Limit Reached"). `nil`
    /// on success. Non-nil signals the UI to present a failure alert.
    public var failureTitle: LocalizedStringResource?
    /// An optional longer explanation shown under `failureTitle`.
    ///
    /// Modelled rather than typed `String` because it is BOTH: most failures
    /// carry our own wording, and one carries whatever Seerr sent back. It was a
    /// String marked as server text, which was true for exactly one of five
    /// cases — the other four rendered our copy verbatim and never reached the
    /// catalog. An enum makes each caller say which it is.
    public enum FailureMessage: Equatable, Sendable {
        /// Plozz's own wording — translatable.
        case copy(LocalizedStringResource)
        /// Text the Seerr server sent us — rendered verbatim, never translated.
        case serverText(String)
    }

    public var failureMessage: FailureMessage?

    public init(status: MediaAvailabilityStatus? = nil, failureTitle: LocalizedStringResource? = nil, failureMessage: FailureMessage? = nil) {
        self.status = status
        self.failureTitle = failureTitle
        self.failureMessage = failureMessage
    }

    /// Whether the request succeeded (a status is present and no failure title).
    public var isSuccess: Bool { failureTitle == nil }

    public static func success(_ status: MediaAvailabilityStatus) -> MediaRequestActionResult {
        MediaRequestActionResult(status: status)
    }

    public static func failure(title: LocalizedStringResource,
                               message: FailureMessage? = nil) -> MediaRequestActionResult {
        MediaRequestActionResult(failureTitle: title, failureMessage: message)
    }
}
