import Foundation

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
    public var failureTitle: String?
    /// An optional longer explanation shown under `failureTitle`.
    public var failureMessage: String?

    public init(status: MediaAvailabilityStatus? = nil, failureTitle: String? = nil, failureMessage: String? = nil) {
        self.status = status
        self.failureTitle = failureTitle
        self.failureMessage = failureMessage
    }

    /// Whether the request succeeded (a status is present and no failure title).
    public var isSuccess: Bool { failureTitle == nil }

    public static func success(_ status: MediaAvailabilityStatus) -> MediaRequestActionResult {
        MediaRequestActionResult(status: status)
    }

    public static func failure(title: String, message: String? = nil) -> MediaRequestActionResult {
        MediaRequestActionResult(failureTitle: title, failureMessage: message)
    }
}
