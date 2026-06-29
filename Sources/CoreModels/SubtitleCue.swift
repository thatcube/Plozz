import Foundation
import CoreGraphics

/// A single, engine-agnostic subtitle event ready to be drawn by Plozz's own
/// renderer.
///
/// This is the **one cue model** the whole subtitle pipeline converges on. Every
/// source — embedded text or bitmap tracks decoded by Plozzigen (AetherEngine),
/// provider sidecar files (Jellyfin/Plex `deliveryURL`), searched/downloaded
/// `.srt/.ass/.vtt/.sup` files, and (future) on-device generated subtitles — is
/// normalized into a stream of these. Nothing downstream of the normalizer needs
/// to know where a cue came from.
///
/// Deliberately mirrors AetherEngine's `SubtitleCue` (`.text` / `.image` body,
/// `CGImage` + normalized rect for bitmaps) so the Plozzigen adapter is a 1:1
/// pass-through rather than a translation layer.
///
/// Cues are **ephemeral runtime values** — they are never persisted. That is a
/// deliberate architectural property: it means the model can grow (inline word
/// timing for karaoke, ASS run styling, ruby/furigana annotations) without any
/// migration concern. The stable axis is the `.text` / `.image` enum; the
/// associated `SubtitleText` is a struct precisely so new fields are additive.
public struct SubtitleCue: Identifiable, Sendable {
    /// Monotonic per playback session. Sufficient for SwiftUI diffing and for
    /// addressing a cue when applying a per-cue sync shift.
    public let id: Int
    /// Cue start, in seconds on the media timeline, **before** any user offset.
    public var start: Double
    /// Cue end, in seconds on the media timeline, **before** any user offset.
    public var end: Double
    public var body: Body

    public enum Body: Sendable {
        case text(SubtitleText)
        /// A pre-rendered bitmap cue (PGS / HDMV-PGS / DVB / DVD). Decoded by the
        /// engine; the renderer only composites + luminance-clamps it.
        case image(SubtitleImage)
    }

    public init(id: Int, start: Double, end: Double, body: Body) {
        self.id = id
        self.start = start
        self.end = end
        self.body = body
    }

    /// Convenience: plain display string for text cues (nil for bitmap cues).
    public var text: String? {
        if case .text(let t) = body { return t.string }
        return nil
    }

    public var isImage: Bool {
        if case .image = body { return true }
        return false
    }
}

extension SubtitleCue: Equatable {
    /// Identity-based equality (id + timing). We never compare `CGImage`
    /// contents — the monotonic `id` already uniquely identifies a cue within a
    /// session, which is all SwiftUI diffing needs. Mirrors AetherEngine.
    public static func == (lhs: SubtitleCue, rhs: SubtitleCue) -> Bool {
        lhs.id == rhs.id && lhs.start == rhs.start && lhs.end == rhs.end
    }
}

/// The text payload of a cue. A struct (not a bare `String`) so the model can
/// grow additively: today it carries the plain string, italic emphasis, and an
/// optional positional alignment parsed from ASS `\an` tags. Tomorrow it can
/// carry per-word karaoke timing or inline colour runs **without** changing the
/// `SubtitleCue.Body` enum or any call site that only reads `.string`.
public struct SubtitleText: Sendable, Equatable {
    /// Display text with markup stripped (newlines preserved).
    public var string: String
    public var isItalic: Bool
    public var isBold: Bool
    /// Where the cue wants to sit, when the source positions it (ASS signs,
    /// captions). `nil` means "use the user's configured default position".
    public var alignment: SubtitleAlignment?

    public init(
        _ string: String,
        isItalic: Bool = false,
        isBold: Bool = false,
        alignment: SubtitleAlignment? = nil
    ) {
        self.string = string
        self.isItalic = isItalic
        self.isBold = isBold
        self.alignment = alignment
    }
}

/// A decoded bitmap subtitle image. The `CGImage` is fully rendered (RGBA,
/// premultiplied alpha); `normalizedRect` is `[0, 1]` against the *source* video
/// frame, so the renderer multiplies it by the on-screen video rect to place it.
/// Matches AetherEngine's `SubtitleImage` so Plozzigen cues pass straight through.
public struct SubtitleImage: @unchecked Sendable {
    public var cgImage: CGImage
    public var normalizedRect: CGRect

    public init(cgImage: CGImage, normalizedRect: CGRect) {
        self.cgImage = cgImage
        self.normalizedRect = normalizedRect
    }
}

/// ASS/SSA `\an` alignment numbering (numpad layout): 1–3 bottom, 4–6 middle,
/// 7–9 top; columns left/centre/right. Enough to honour positioned signs and to
/// drive dual-subtitle placement without pinning us to a single layout.
public enum SubtitleAlignment: Int, Sendable, Equatable, CaseIterable {
    case bottomLeft = 1, bottomCenter = 2, bottomRight = 3
    case middleLeft = 4, middleCenter = 5, middleRight = 6
    case topLeft = 7, topCenter = 8, topRight = 9

    public enum Vertical: Sendable { case top, middle, bottom }
    public enum Horizontal: Sendable { case leading, center, trailing }

    public var vertical: Vertical {
        switch self {
        case .topLeft, .topCenter, .topRight: return .top
        case .middleLeft, .middleCenter, .middleRight: return .middle
        default: return .bottom
        }
    }

    public var horizontal: Horizontal {
        switch self {
        case .bottomLeft, .middleLeft, .topLeft: return .leading
        case .bottomRight, .middleRight, .topRight: return .trailing
        default: return .center
        }
    }
}

// MARK: - Active-cue selection (pure, testable)

public extension Sequence where Element == SubtitleCue {
    /// The cues visible at `time` (seconds), after applying an optional global
    /// `offset` (positive = show subtitles later). Overlapping cues are allowed
    /// (e.g. a positioned sign on top of dialogue), so this returns all matches.
    func active(at time: Double, offset: Double = 0) -> [SubtitleCue] {
        let t = time - offset
        return filter { t >= $0.start && t < $0.end }
    }
}
