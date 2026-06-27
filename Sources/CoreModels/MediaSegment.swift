import Foundation

/// A time range within a playable item that the server has tagged as a
/// structural segment — an intro, the closing credits, a recap, etc.
///
/// Both backends expose server-detected markers, normalised here so the player
/// stays provider-agnostic (the dual-provider mandate):
///  * **Jellyfin** → `GET /MediaSegments/{itemId}` (`Intro`/`Outro`/… with
///    100-nanosecond `StartTicks`/`EndTicks`).
///  * **Plex** → `GET /library/metadata/{id}?includeMarkers=1` (`<Marker
///    type="intro|credits" startTimeOffset endTimeOffset>` in milliseconds).
///
/// Times are stored in **seconds** so the player can compare them directly
/// against the engine's `currentTime` without unit juggling.
public struct MediaSegment: Codable, Equatable, Sendable, Identifiable {
    /// The kind of segment. Only `.intro` and `.credits` are "skippable" today
    /// (what the Skip Intros toggle acts on); the rest are modelled so the data
    /// is ready if more behaviours are added later, per the flexibility mandate.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case intro
        case credits
        case recap
        case preview
        case commercial
        case unknown

        /// The label shown on the in-player skip button for this kind.
        public var skipActionLabel: String {
            switch self {
            case .intro: return "Skip Intro"
            case .credits: return "Skip Credits"
            case .recap: return "Skip Recap"
            case .preview: return "Skip Preview"
            case .commercial: return "Skip"
            case .unknown: return "Skip"
            }
        }
    }

    public var id: String
    public var kind: Kind
    /// Inclusive start, in seconds from the beginning of the item.
    public var start: TimeInterval
    /// Exclusive end, in seconds — the position the player seeks to on skip.
    public var end: TimeInterval

    public init(id: String = UUID().uuidString, kind: Kind, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// Segments the Skip Intros feature offers a button for. Intros and credits
    /// only — recaps/previews/commercials are detected but not auto-offered.
    public var isSkippable: Bool {
        kind == .intro || kind == .credits
    }

    /// Whether `position` (seconds) falls inside this segment's window. A small
    /// trailing margin is excluded so the button doesn't linger for the final
    /// frame, and a tiny lead-in tolerance is allowed so it appears promptly.
    public func contains(_ position: TimeInterval) -> Bool {
        position >= start - 0.25 && position < end - 0.25
    }
}

public extension Array where Element == MediaSegment {
    /// The skippable segment whose window currently contains `position`, if any.
    /// Intros win ties over credits since an intro can never overlap credits in
    /// practice; if data is malformed the earliest-starting match is returned.
    func activeSkippable(at position: TimeInterval) -> MediaSegment? {
        self.filter { $0.isSkippable && $0.contains(position) }
            .min { $0.start < $1.start }
    }
}
