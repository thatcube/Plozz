import Foundation
import CoreGraphics

/// A single, engine-agnostic subtitle event ready to be drawn by Plozz's own
/// renderer.
///
/// This is the **one cue model** the whole subtitle pipeline converges on. Every
/// source — embedded text or bitmap tracks decoded by Plozzigen (AetherEngine),
/// provider sidecar files (Jellyfin/Plex delivery sources), searched/downloaded
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
/// grow additively: today it carries the plain string, italic/bold emphasis, an
/// optional ``SubtitleCueLayout`` describing where a *source-positioned* cue
/// wants to sit, and — crucially — the **raw ASS event** so rich styling is
/// preserved rather than flattened. Tomorrow it can carry per-word karaoke
/// timing or resolved inline colour runs **without** changing the
/// `SubtitleCue.Body` enum or any call site that only reads `.string`.
public struct SubtitleText: Sendable, Equatable {
    /// Display text with markup stripped (newlines preserved). Always renderable
    /// by the current renderer, regardless of the source format.
    public var string: String
    public var isItalic: Bool
    public var isBold: Bool
    /// Where the cue wants to sit when the source positions it (ASS
    /// `\an`/`\pos`/`MarginL/R/V`, VTT `line`/`position`/`region`, captions).
    /// `nil` means "use the user's configured default dialogue position".
    ///
    /// This supersedes the old bare `\an` enum: it preserves an explicit anchor
    /// point and per-edge margins so a positioned sign is reconstructed exactly,
    /// not snapped to one of nine planes. The convenience ``alignment`` accessor
    /// still returns the plane for call sites that only need it.
    public var layout: SubtitleCueLayout?
    /// The **raw ASS/SSA event line** (`Layer,Start,End,Style,…,Text` *including*
    /// override tags) when the source is ASS and the engine was asked to preserve
    /// markup (AetherEngine `LoadOptions.preserveASSMarkup`, whose `.text` carries
    /// exactly this string). Plain sources (SRT/VTT/PGS) leave it `nil`.
    ///
    /// We keep it so a future ASS styling pass can reconstruct inline
    /// colour/karaoke/positioning **without** the cue pipeline having flattened
    /// the data away first — the single most expensive-to-reverse mistake in a
    /// subtitle stack. The matching track-level `[Script Info]`/`[V4+ Styles]`
    /// header (`SubtitleCueStream.metadata.assHeader`) and font attachments travel
    /// with the cue stream's *metadata* (introduced with the Plozzigen adapter),
    /// not on every cue.
    public var rawASS: String?

    /// The `\an`-style plane of this cue's layout, or `nil` for default-lane
    /// dialogue. Computed passthrough so existing call sites keep working while
    /// the richer ``layout`` carries anchor/margins underneath.
    public var alignment: SubtitleAlignment? { layout?.alignment }

    /// Back-compatible initializer: a bare ``SubtitleAlignment`` (or `nil`) is
    /// wrapped into a source-positioned ``SubtitleCueLayout``. Used by simple
    /// sources (SRT/VTT) and the preview harness.
    public init(
        _ string: String,
        isItalic: Bool = false,
        isBold: Bool = false,
        alignment: SubtitleAlignment? = nil,
        rawASS: String? = nil
    ) {
        self.string = string
        self.isItalic = isItalic
        self.isBold = isBold
        self.layout = alignment.map { SubtitleCueLayout(alignment: $0) }
        self.rawASS = rawASS
    }

    /// Rich initializer for sources that carry a full ``SubtitleCueLayout``
    /// (ASS `\pos`/margins, VTT regions, bitmap absolute placement).
    public init(
        _ string: String,
        isItalic: Bool = false,
        isBold: Bool = false,
        layout: SubtitleCueLayout?,
        rawASS: String? = nil
    ) {
        self.string = string
        self.isItalic = isItalic
        self.isBold = isBold
        self.layout = layout
        self.rawASS = rawASS
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

/// Normalized per-edge insets in `[0, 1]` against the video rect. Mirrors ASS
/// `MarginL`/`MarginR`/`MarginV` and a WebVTT region box, kept resolution-neutral
/// so the renderer multiplies by the on-screen video rect at draw time.
public struct SubtitleEdgeInsets: Sendable, Equatable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let zero = SubtitleEdgeInsets()

    public var isZero: Bool { top == 0 && leading == 0 && bottom == 0 && trailing == 0 }
}

/// Where a *source-positioned* cue wants to sit, normalized across subtitle
/// formats so the renderer can place a sign/caption without knowing whether it
/// came from ASS (`\an` + `\pos` + `MarginL/R/V`), WebVTT (`line`/`position`/
/// `region`) or a bitmap track (absolute rect, carried separately on
/// ``SubtitleImage``). A cue's text carries a layout only when the source
/// positions it; a `nil` layout means "default dialogue lane", which the
/// renderer seats at the user's configured, freely-movable position.
///
/// This is the vocabulary the renderer reasons in: it splits the active cues
/// into **planes/lanes** — source-positioned cues drawn independently at their
/// anchor against the video rect, default dialogue stacked in the user lane, and
/// dual-subtitle tracks in their own lane — instead of collapsing everything to
/// one block alignment.
public struct SubtitleCueLayout: Sendable, Equatable {
    /// The numpad plane (ASS `\an`; a bucketed WebVTT `line`/`position`). Drives
    /// which corner of the cue box the anchor pins and multi-line justification.
    public var alignment: SubtitleAlignment
    /// An explicit normalized anchor point in `[0, 1]` against the *video rect*
    /// (ASS `\pos`, WebVTT `position`/`line` percentages). When set it wins over
    /// the `alignment` plane for *placement*; `alignment` still governs text
    /// justification and which point of the box sits on the anchor. `nil` = place
    /// by plane + `margins` only.
    public var anchor: CGPoint?
    /// Per-edge insets applied on top of the plane (ASS `MarginL/R/V`, VTT region).
    public var margins: SubtitleEdgeInsets
    /// `true` when the *source* explicitly placed this cue (a sign/caption), vs.
    /// the renderer choosing the default lane. The renderer keeps source-placed
    /// cues pinned to their plane while letting the user move dialogue, so a top
    /// sign never drags dialogue with it.
    public var isSourcePositioned: Bool

    public init(
        alignment: SubtitleAlignment = .bottomCenter,
        anchor: CGPoint? = nil,
        margins: SubtitleEdgeInsets = .zero,
        isSourcePositioned: Bool = true
    ) {
        self.alignment = alignment
        self.anchor = anchor
        self.margins = margins
        self.isSourcePositioned = isSourcePositioned
    }
}

// MARK: - Active-cue selection (pure, testable)

public extension Sequence where Element == SubtitleCue {
    /// The cues visible at `time` (seconds), after applying an optional global
    /// `offset` (positive = show subtitles later). Overlapping cues are allowed
    /// (e.g. a positioned sign on top of dialogue), so this returns all matches.
    ///
    /// This is the **simple O(n) path** kept for the preview harness and unit
    /// tests. Live playback drives an indexed ``SubtitleCueStore`` /
    /// ``SubtitleCueTimeline`` instead, which answers the same question in
    /// O(log n + k) and only re-emits on cue-boundary crossings.
    func active(at time: Double, offset: Double = 0) -> [SubtitleCue] {
        let t = time - offset
        return filter { t >= $0.start && t < $0.end }
    }
}
