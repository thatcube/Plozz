import Foundation

/// Parses **text** subtitle payloads (SubRip / WebVTT) into the unified
/// ``SubtitleCueStream`` the renderer consumes.
///
/// This is the canonical text-cue producer for the v2 subtitle architecture: a
/// provider sidecar (Jellyfin `Stream.vtt`, Plex `.srt`/`.vtt`/`.ass`), a
/// searched and downloaded subtitle file, or any embedded text track the host
/// hands us as a string all flow through here into one normalized model. It
/// handles SubRip and WebVTT (which differ, in practice, by just their header
/// and the `,` vs `.` millisecond separator) plus a **plain-text** extraction of
/// ASS/SSA `[Events]` (timing + text with override tags stripped; full styling
/// is a later `rawASS` pass). Bitmap (PGS/DVB/DVD) streams are produced elsewhere
/// (engine adapters).
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
        let cues = format.isASSFamily ? parseASSCues(unified) : parseCuesNormalized(unified)
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
        let unified = normalizeLineEndings(text)
        return detectFormat(unified).isASSFamily
            ? parseASSCues(unified)
            : parseCuesNormalized(unified)
    }

    // MARK: - Byte decoding

    /// Decodes raw subtitle-file bytes into text, tolerating the encodings
    /// sidecar files actually appear in. Tries, in order: an explicit BOM
    /// (UTF-8 / UTF-16), then strict UTF-8, then Windows-1252, then ISO Latin-1 —
    /// the last of which decodes *any* byte sequence, so a non-empty input never
    /// returns `nil`. Many real-world `.srt` files (older/European subs, and the
    /// raw sidecar parts Plex serves) are Windows-1252/Latin-1 rather than UTF-8;
    /// decoding them as UTF-8 only would fail and silently show no subtitles.
    public static func decodeText(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        for encoding: String.Encoding in [.utf8, .windowsCP1252, .isoLatin1] {
            if let decoded = String(data: data, encoding: encoding) { return decoded }
        }
        return nil
    }

    // MARK: - Format detection

    private static func detectFormat(_ unified: String) -> SubtitleFormat {
        let head = unified.drop(while: { $0 == "\u{FEFF}" || $0 == "\n" || $0 == " " || $0 == "\t" })
        if head.hasPrefix("WEBVTT") { return .webVTT }
        // ASS/SSA script files open with a `[Script Info]` (or another bracketed)
        // section header. `[V4+ Styles]` denotes ASS, `[V4 Styles]` legacy SSA;
        // both parse identically here, so the split is purely cosmetic metadata.
        if head.hasPrefix("[Script Info]") || head.hasPrefix("[V4") || head.hasPrefix("[Events]") {
            return unified.contains("[V4 Styles]") && !unified.contains("[V4+ Styles]") ? .ssa : .ass
        }
        return .srt
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

    // MARK: - ASS / SSA events

    /// Extracts plain, renderable cues from an ASS/SSA script's `[Events]`
    /// section. This is deliberately a **plain-text** extraction: it reads each
    /// `Dialogue:` line's timing and text, strips `{\…}` override blocks, and
    /// converts `\N`/`\n` line breaks — enough to actually display an ASS sidecar
    /// (common on anime, and served raw by Plex) instead of nothing. The full,
    /// untouched event text is preserved on each cue's ``SubtitleText/rawASS`` so
    /// a later styling pass can reconstruct inline colour/karaoke/positioning
    /// without this stage having flattened it away.
    private static func parseASSCues(_ unified: String) -> [SubtitleCue] {
        let clean = unified.replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // ASS v4+ default Events column order, overridden by the section's
        // `Format:` line (SSA orders Start/End/Text the same, so the defaults
        // also cover headerless files).
        var startIdx = 1, endIdx = 2, textIdx = 9
        var inEvents = false
        var parsed: [(start: Double, end: Double, text: SubtitleText)] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.caseInsensitiveCompare("[Events]") == .orderedSame
                continue
            }
            guard inEvents, let colon = trimmed.firstIndex(of: ":") else { continue }
            let descriptor = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let payload = String(trimmed[trimmed.index(after: colon)...])

            if descriptor == "format" {
                let cols = payload.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if let i = cols.firstIndex(of: "start") { startIdx = i }
                if let i = cols.firstIndex(of: "end") { endIdx = i }
                if let i = cols.firstIndex(of: "text") { textIdx = i }
                continue
            }
            // Only spoken events; skip `Comment:`, `Picture:`, `Sound:`, etc.
            guard descriptor == "dialogue" else { continue }

            // Text is the final column and may itself contain commas, so cap the
            // split at `textIdx` — everything past it stays in one piece.
            let fields = payload.split(separator: ",", maxSplits: textIdx,
                                       omittingEmptySubsequences: false).map(String.init)
            guard fields.count > textIdx,
                  let start = parseASSTimestamp(fields[startIdx]),
                  let end = parseASSTimestamp(fields[endIdx]),
                  end > start else { continue }

            let body = cleanASSText(fields[textIdx])
            guard !body.string.isEmpty else { continue }
            parsed.append((start, end, body))
        }

        let sorted = parsed.sorted { $0.start < $1.start }
        return sorted.enumerated().map { index, cue in
            SubtitleCue(id: index, start: cue.start, end: cue.end, body: .text(cue.text))
        }
    }

    /// Parses an ASS timestamp `H:MM:SS.cc` (centiseconds) into seconds.
    private static func parseASSTimestamp(_ token: String) -> Double? {
        let parts = token.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]),
              m < 60, s < 60 else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// Strips ASS override blocks (`{\…}`) and converts ASS line breaks to plain
    /// display text, capturing whole-cue italic/bold (`{\i1}`/`{\b1}`) the way the
    /// SRT/VTT path captures `<i>`/`<b>`. The untouched event text is kept as
    /// `rawASS` for a future rich pass.
    private static func cleanASSText(_ raw: String) -> SubtitleText {
        let lowered = raw.lowercased()
        let isItalic = lowered.contains("\\i1")
        let isBold = lowered.contains("\\b1")

        // Drop `{...}` override blocks (depth-counted for the rare nested case).
        var withoutOverrides = ""
        withoutOverrides.reserveCapacity(raw.count)
        var depth = 0
        for ch in raw {
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                withoutOverrides.append(ch)
            }
        }

        // ASS line breaks: `\N` (hard) and `\n` (soft) → newline; `\h` → NBSP.
        let text = withoutOverrides
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: "\u{00A0}")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SubtitleText(text, isItalic: isItalic, isBold: isBold, rawASS: raw)
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
