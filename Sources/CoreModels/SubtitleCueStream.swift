import Foundation
import CoreGraphics

/// The source format a cue stream was parsed from. Drives whether stream-level
/// ASS styling context is meaningful and how a future styling pass interprets
/// each cue's ``SubtitleText/rawASS`` event.
public enum SubtitleFormat: String, Sendable, Equatable, Codable, CaseIterable {
    case srt
    case webVTT
    case ass
    case ssa
    case pgs
    case dvbSub
    case dvdSub
    case ttml
    case unknown

    /// `true` for formats whose cues may carry rich `rawASS` events plus a
    /// stream-level ``SubtitleStreamMetadata/assHeader`` (so the renderer's
    /// future styling pass should consult them to resolve named styles).
    public var isASSFamily: Bool { self == .ass || self == .ssa }

    /// `true` for pre-rendered bitmap formats whose cues are `.image` bodies.
    public var isImageBased: Bool { self == .pgs || self == .dvbSub || self == .dvdSub }
}

/// A font file attached to an ASS / Matroska subtitle track, needed to render
/// its `\fn` font references faithfully. Carried at **stream** level (one copy),
/// never duplicated onto every cue.
public struct SubtitleFontAttachment: Sendable, Equatable {
    public var fileName: String
    public var data: Data

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }
}

/// Stream-level facts about a subtitle track, independent of the individual
/// cues. The ASS `[Script Info]` / `[V4+ Styles]` header and any embedded fonts
/// live here — once per stream, not on every cue — so a styling pass can resolve
/// named styles and fonts while each cue keeps only its own `rawASS` event. The
/// rest (format, language, source track id) lets selection and the subtitle menu
/// round-trip a stream back to its originating ``MediaTrack``.
public struct SubtitleStreamMetadata: Sendable, Equatable {
    public var format: SubtitleFormat
    /// BCP-47 / ISO language code if known (e.g. `en`, `jpn`).
    public var language: String?
    /// Human label for the menu (e.g. "English (SDH)", "Signs & Songs").
    public var title: String?
    /// The provider/engine track id this stream was decoded from, so selection
    /// and the menu can map the rendered stream back to its `MediaTrack`.
    public var sourceTrackID: Int?
    public var isForced: Bool
    public var isHearingImpaired: Bool
    /// The ASS `[Script Info]` + `[V4+ Styles]` header (everything before
    /// `[Events]`), preserved so named styles resolve. `nil` for non-ASS sources.
    public var assHeader: String?
    /// Fonts embedded in the container/track, for this stream's `\fn` references.
    public var fontAttachments: [SubtitleFontAttachment]
    /// The native authoring resolution (ASS `PlayResX`/`PlayResY`) that `\pos`
    /// and margins are expressed against, so the renderer can scale normalized
    /// layout to the on-screen video rect. `nil` when unknown (SRT/VTT).
    public var referenceSize: CGSize?

    public init(
        format: SubtitleFormat,
        language: String? = nil,
        title: String? = nil,
        sourceTrackID: Int? = nil,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        assHeader: String? = nil,
        fontAttachments: [SubtitleFontAttachment] = [],
        referenceSize: CGSize? = nil
    ) {
        self.format = format
        self.language = language
        self.title = title
        self.sourceTrackID = sourceTrackID
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.assHeader = assHeader
        self.fontAttachments = fontAttachments
        self.referenceSize = referenceSize
    }
}

/// A complete decoded subtitle track: stream-level ``SubtitleStreamMetadata``
/// plus all of its cues.
///
/// This is the unit that parsers (provider sidecars, searched/downloaded files)
/// and engine adapters (Plozzigen / AetherEngine) produce, and that the
/// ``SubtitleCueStore`` ingests. The renderer never receives a whole stream — the
/// store time-filters it into the small active slice the overlay draws — but
/// subtitle selection, the menu, and the future ASS styling pass read its
/// metadata. Like ``SubtitleCue``, a stream is an **ephemeral runtime value**;
/// it is never persisted.
public struct SubtitleCueStream: Identifiable, Sendable {
    /// Stable per playback session (typically the originating track id).
    public let id: Int
    public var metadata: SubtitleStreamMetadata
    public var cues: [SubtitleCue]

    public init(id: Int, metadata: SubtitleStreamMetadata, cues: [SubtitleCue]) {
        self.id = id
        self.metadata = metadata
        self.cues = cues
    }

    public var isEmpty: Bool { cues.isEmpty }
}

extension SubtitleCueStream: Equatable {
    /// Identity + cue-identity equality (never compares bitmap contents), mirroring
    /// ``SubtitleCue``'s cheap, diffing-oriented equality.
    public static func == (lhs: SubtitleCueStream, rhs: SubtitleCueStream) -> Bool {
        lhs.id == rhs.id && lhs.metadata == rhs.metadata && lhs.cues == rhs.cues
    }
}
