import Foundation

/// The primary call-to-action a Home **hero** slide offers for a title, derived
/// purely from the title's discovery-backend `availability` (Seerr/Overseerr) and
/// live `downloadProgress`, plus whether Seerr is currently connected.
///
/// Kept in `CoreModels` (Foundation-only, no SwiftUI, no Seerr import) so the
/// decision is exhaustively unit-testable and the UI never reaches into the Seerr
/// module to figure out which button to show.
public enum HeroCTA: Equatable, Sendable {
    /// Play/Resume — an ordinary library item, or a featured title already
    /// available (fully or partially) in the library.
    case play
    /// A one-tap "Request" — a featured title that isn't in the library yet and
    /// can be requested, shown only while Seerr is connected.
    case request
    /// The title has an approved request that's downloading. `progress` is the
    /// aggregate fetched fraction (`0..<1`) when the backend reports sizes, else
    /// `nil` (queued / size not yet known) so the UI shows a plain "Downloading".
    case downloading(progress: Double?)
    /// A request exists but is still awaiting approval — a "Requested" status.
    case requested
    /// No Play/Request button: a featured title that isn't owned and can't be
    /// requested because Seerr isn't connected. The slide still shows in the
    /// carousel; it just offers no primary action.
    case unavailable
}

public extension MediaItem {
    /// The hero primary CTA for this item given the current Seerr connection.
    func heroCTA(seerConnected: Bool) -> HeroCTA {
        Self.heroCTA(
            availability: availability,
            downloadProgress: downloadProgress,
            seerConnected: seerConnected
        )
    }

    /// Pure decision used by ``heroCTA(seerConnected:)`` and directly by the hero
    /// (which may apply a just-tapped optimistic `availability` override).
    ///
    /// - Ordinary library items (`availability == nil`) always ``HeroCTA/play``.
    /// - Owned featured titles (`available`/`partiallyAvailable`) also ``play``.
    /// - Everything else needs Seerr connected to offer any action; otherwise
    ///   ``unavailable`` (the slide shows with no Play/Request button).
    static func heroCTA(
        availability: MediaAvailabilityStatus?,
        downloadProgress: Double?,
        seerConnected: Bool
    ) -> HeroCTA {
        guard let availability else { return .play }
        switch availability {
        case .available, .partiallyAvailable:
            return .play
        case .pending, .processing, .unknown, .deleted:
            guard seerConnected else { return .unavailable }
            switch availability {
            case .pending: return .requested
            case .processing: return .downloading(progress: downloadProgress)
            default: return .request // .unknown / .deleted are requestable
            }
        }
    }
}
