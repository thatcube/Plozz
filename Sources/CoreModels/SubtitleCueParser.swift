import Foundation

/// Parses **text** subtitle payloads (SubRip / WebVTT) into the unified
/// ``SubtitleCueStream`` the renderer consumes.
///
/// This is the canonical text-cue producer for the v2 subtitle architecture: a
/// provider sidecar (Jellyfin `Stream.vtt`, Plex `.srt`/`.vtt`), a searched and
/// downloaded subtitle file, or any embedded text track the host hands us as a
/// string all flow through here into one normalized model. Bitmap (PGS/DVB/DVD)
/// and rich ASS/SSA streams are produced elsewhere (engine adapters), so this
/// parser deliberately handles only the two line-based text formats — which
/// differ, in practice, by just their header and the `,` vs `.` millisecond
/// separator.
///
/// It is **pure** (Foundation only, no AVFoundation/UIKit), so it lives in
/// CoreModels next to the model it builds and is exhaustively unit-tested.
public enum SubtitleCueParser {

    /// Parses `text` (auto-detecting SubRip vs WebVTT) into a cue stream.
    ///
    /// - Parameters:
    ///   - text: the raw subtitle file contents.
    ///   - id: stream id (typically the originating `MediaTrack.id`).
    ///   - language: BCP-47/ISO language code, if the caller knows it.
    ///   - title: human label for the menu, if known.
    ///   - sourceTrackID: the provider/engine track id, so selection can map the
    ///     rendered stream back to its `MediaTrack` (defaults to `id`).
    ///   - isForced / isHearingImpaired: track flags carried into metadata.
    /// - Returns: a stream whose cues are sorted by start time and assigned
    ///   monotonic ids. Malformed or empty cues are skipped; a completely
    ///   unparseable input yields an empty stream (never throws).
    public static func parse(
        _ text: String,
        id: Int = 0,
        language: String? = nil,
        title: String? = nil,
        sourceTrackID: Int? = nil,
        isForced: Bool = false,
        isHearingImpaired: Bool = false
    ) -> SubtitleCueStream {
        let unified = normalizeLineEndings(text)
        let format = detectFormat(unified)
        let cues = parseCuesNormalized(unified)
        let metadata = SubtitleStreamMetadata(
            format: format,
            language: language,
            title: title,
            sourceTrackID: sourceTrackID ?? id,
            isForced: isForced,
            isHearingImpaired: isHearingImpaired
        )
        return SubtitleCueStream(id: id, metadata: metadata, cues: cues)
    }

    /// Convenience: just the cues, for callers that don't need stream metadata
    /// (the preview harness, tests, quick checks).
    public static func parseCues(_ text: String) -> [SubtitleCue] {
        parseCuesNormalized(normalizeLineEndings(text))
    }

    // MARK: - Format detection

    private static func detectFormat(_ unified: String) -> SubtitleFormat {
        let head = unified.drop(while: { $0 == "\u{FEFF}" || $0 == "\n" || $0 == " " || $0 == "\t" })
        return head.hasPrefix("WEBVTT") ? .webVTT : .srt
    }

    // MARK: - Cue parsing

    private static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Splits the (line-ending-normalized) document into blank-line-separated
    /// blocks, parses each timing block into a cue, and returns them sorted by
    /// start with monotonic ids. Non-cue blocks (the `WEBVTT` header, `NOTE`,
    /// `STYLE`, `REGION`) are ignored.
    private static func parseCuesNormalized(_ unified: String) -> [SubtitleCue] {
        let blocks = unified
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: "\n\n")

        var parsed: [(start: Double, end: Double, text: SubtitleText)] = []

        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }

            // Skip WebVTT structural blocks even if they somehow contain "-->".
            let firstWord = lines.first?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
            if firstWord.hasPrefix("NOTE") || firstWord.hasPrefix("STYLE") || firstWord.hasPrefix("REGION") {
                continue
            }

            guard let timing = parseTimingLine(lines[timingIndex]) else { continue }
            guard timing.end > timing.start else { continue }

            let textLines = lines[(timingIndex + 1)...]
            let raw = textLines.joined(separator: "\n")
            let cleaned = cleanText(raw)
            guard !cleaned.string.isEmpty else { continue }

            var body = cleaned
            if let layout = timing.layout { body.layout = layout }
            parsed.append((timing.start, timing.end, body))
        }

        let sorted = parsed.sorted { $0.start < $1.start }
        return sorted.enumerated().map { index, cue in
            SubtitleCue(id: index, start: cue.start, end: cue.end, body: .text(cue.text))
        }
    }

    // MARK: - Timing line

    private struct Timing {
        var start: Double
        var end: Double
        var layout: SubtitleCueLayout?
    }

    /// Parses `00:00:01,000 --> 00:00:04,000 position:50% line:84%` (SRT or VTT),
    /// returning the start/end seconds and any WebVTT cue-setting layout.
    private static func parseTimingLine(_ line: String) -> Timing? {
        guard let arrowRange = line.range(of: "-->") else { return nil }
        let startToken = line[..<arrowRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let afterArrow = line[arrowRange.upperBound...].trimmingCharacters(in: .whitespaces)

        // The end timestamp is the first whitespace-delimited token after the
        // arrow; anything following it is WebVTT cue settings.
        let afterParts = afterArrow.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let endToken = afterParts.first.map(String.init) else { return nil }
        guard let start = parseTimestamp(startToken), let end = parseTimestamp(endToken) else { return nil }

        let settings = afterParts.count > 1 ? String(afterParts[1]) : ""
        return Timing(start: start, end: end, layout: parseCueSettings(settings))
    }

    /// Parses `[HH:]MM:SS[,.]mmm` into seconds. Tolerates 1–3 millisecond digits
    /// and the WebVTT-optional hours field.
    private static func parseTimestamp(_ token: String) -> Double? {
        let cleaned = token.replacingOccurrences(of: ",", with: ".")
        let dotSplit = cleaned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let hms = dotSplit[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard hms.count == 2 || hms.count == 3 else { return nil }

        let hours: Int
        let minutes: Int
        let seconds: Int
        if hms.count == 3 {
            guard let h = Int(hms[0]), let m = Int(hms[1]), let s = Int(hms[2]) else { return nil }
            hours = h; minutes = m; seconds = s
        } else {
            guard let m = Int(hms[0]), let s = Int(hms[1]) else { return nil }
            hours = 0; minutes = m; seconds = s
        }
        guard minutes < 60, seconds < 60 else { return nil }

        var fraction = 0.0
        if dotSplit.count == 2, !dotSplit[1].isEmpty {
            let ms = dotSplit[1].prefix(while: \.isNumber)
            if let value = Double(ms) {
                fraction = value / pow(10.0, Double(ms.count))
            }
        }
        return Double(hours * 3600 + minutes * 60 + seconds) + fraction
    }

    // MARK: - WebVTT cue settings → layout

    /// Maps WebVTT cue settings (`align:`, `line:`, `position:`) to a
    /// ``SubtitleCueLayout``. Only an explicit position/line produces a
    /// *source-positioned* layout; a plain `align:` (justification only) and the
    /// common no-settings case leave the cue in the user's default dialogue lane.
    private static func parseCueSettings(_ settings: String) -> SubtitleCueLayout? {
        guard !settings.isEmpty else { return nil }

        var horizontal: SubtitleAlignment.Horizontal = .center
        var verticalPercent: Double?      // 0 = top, 100 = bottom
        var positionPercent: Double?      // 0 = left, 100 = right
        var sawPlacement = false

        for token in settings.split(separator: " ", omittingEmptySubsequences: true) {
            let pair = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].lowercased()
            let value = String(pair[1])
            switch key {
            case "align":
                switch value.lowercased() {
                case "start", "left": horizontal = .leading
                case "end", "right": horizontal = .trailing
                default: horizontal = .center
                }
            case "line":
                if let pct = percentValue(value) { verticalPercent = pct; sawPlacement = true }
            case "position":
                if let pct = percentValue(value) { positionPercent = pct; sawPlacement = true }
            default:
                break
            }
        }

        guard sawPlacement else { return nil }

        let vertical: SubtitleAlignment.Vertical
        switch verticalPercent {
        case .some(let p) where p <= 33: vertical = .top
        case .some(let p) where p < 66: vertical = .middle
        default: vertical = .bottom
        }

        let alignment = SubtitleAlignment(vertical: vertical, horizontal: horizontal)
        let anchor: CGPoint?
        if let x = positionPercent, let y = verticalPercent {
            anchor = CGPoint(x: x / 100, y: y / 100)
        } else {
            anchor = nil
        }
        return SubtitleCueLayout(alignment: alignment, anchor: anchor, isSourcePositioned: true)
    }

    private static func percentValue(_ value: String) -> Double? {
        let trimmed = value.hasSuffix("%") ? String(value.dropLast()) : value
        // `line:` may be a line number rather than a percent; we only model the
        // percentage form, so a bare integer line is treated as unknown.
        guard value.hasSuffix("%"), let pct = Double(trimmed) else { return nil }
        return min(max(pct, 0), 100)
    }

    // MARK: - Text cleanup

    /// Strips markup to plain display text while capturing whole-cue italic/bold
    /// emphasis (the renderer applies emphasis per cue; per-run colour/karaoke is
    /// a later ``SubtitleText/rawASS`` pass). Decodes the handful of HTML/XML
    /// entities subtitle files actually use.
    private static func cleanText(_ raw: String) -> SubtitleText {
        let lowered = raw.lowercased()
        let isItalic = lowered.contains("<i>") || lowered.contains("<i ")
        let isBold = lowered.contains("<b>") || lowered.contains("<b ")

        let stripped = stripTags(raw)
        let decoded = decodeEntities(stripped)
        let trimmed = decoded
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SubtitleText(trimmed, isItalic: isItalic, isBold: isBold)
    }

    /// Removes any `<...>` tag (`<i>`, `<b>`, `<c.classname>`, `<v Speaker>`,
    /// `<ruby>`/`<rt>`, `<00:00:01.000>` karaoke timestamps, …) without touching
    /// the surrounding text. A lone `<` that isn't a tag is preserved.
    private static func stripTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var inTag = false
        for ch in text {
            if ch == "<" {
                inTag = true
            } else if ch == ">" {
                inTag = false
            } else if !inTag {
                result.append(ch)
            }
        }
        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", "\u{00A0}"),
            ("&lrm;", "\u{200E}"), ("&rlm;", "\u{200F}")
        ]
        for (entity, replacement) in map {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}

private extension SubtitleAlignment {
    /// Composes a numpad plane from a vertical band + horizontal column, the
    /// reverse of ``vertical``/``horizontal``.
    init(vertical: Vertical, horizontal: Horizontal) {
        switch (vertical, horizontal) {
        case (.top, .leading): self = .topLeft
        case (.top, .center): self = .topCenter
        case (.top, .trailing): self = .topRight
        case (.middle, .leading): self = .middleLeft
        case (.middle, .center): self = .middleCenter
        case (.middle, .trailing): self = .middleRight
        case (.bottom, .leading): self = .bottomLeft
        case (.bottom, .center): self = .bottomCenter
        case (.bottom, .trailing): self = .bottomRight
        }
    }
}
