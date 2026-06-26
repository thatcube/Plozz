import Foundation

// MARK: - Lyrics (additive, non-breaking)
//
// A provider-agnostic representation of a track's lyrics. Both backends map to
// this single shape so the Now Playing UI never has to know whether the words
// came from Jellyfin's JSON `LyricDto` or a Plex `.lrc` sidecar stream:
//
//  * Jellyfin returns timestamped lines (ticks) or plain text via
//    `GET /Audio/{id}/Lyrics`.
//  * Plex exposes a `streamType == 4` lyrics stream whose key fetches an `.lrc`
//    (or plain text) file.
//
// `start == nil` on every line means "unsynced" (plain text); any line with a
// timestamp marks the whole set as synced, enabling karaoke-style highlighting.

/// A single line of a song's lyrics, optionally timestamped.
public struct LyricLine: Codable, Hashable, Sendable {
    /// The text of the line. May be empty for an intentional blank/spacer line.
    public var text: String
    /// When this line begins, in seconds from the start of the track. `nil` for
    /// unsynced (plain-text) lyrics.
    public var start: TimeInterval?

    public init(text: String, start: TimeInterval? = nil) {
        self.text = text
        self.start = start
    }
}

/// Where a track's lyrics came from, surfaced as a small attribution badge on
/// the Now Playing lyrics panel. The two servers are first-class; `lrclib` is
/// the keyless public fallback used when the server has none.
public enum LyricsSource: String, Codable, Hashable, Sendable {
    case jellyfin
    case plex
    case lrclib

    /// Human-facing name shown next to the source logo.
    public var displayName: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .lrclib: return "LRCLIB"
        }
    }
}

/// A track's lyrics: an ordered list of lines, synced or plain.
public struct Lyrics: Codable, Hashable, Sendable {
    public var lines: [LyricLine]
    /// Where these lyrics were sourced from, for the attribution badge. `nil`
    /// when unknown.
    public var source: LyricsSource?

    public init(lines: [LyricLine], source: LyricsSource? = nil) {
        self.lines = lines
        self.source = source
    }

    /// Whether any line carries a timestamp (karaoke-capable).
    public var isSynced: Bool { lines.contains { $0.start != nil } }

    /// Whether there is no meaningful content to show.
    public var isEmpty: Bool { lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// Returns a copy stamped with `source`.
    public func taggingSource(_ source: LyricsSource) -> Lyrics {
        var copy = self
        copy.source = source
        return copy
    }

    /// Convenience: plain-text lyrics from a single string, split on newlines.
    public init(plainText: String) {
        let lines = plainText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { LyricLine(text: $0.trimmingCharacters(in: .whitespaces)) }
        self.init(lines: lines)
    }

    /// Parses an LRC file (Plex sidecar lyrics) into timestamped lines. Falls
    /// back to treating the input as plain text when it carries no `[mm:ss.xx]`
    /// timestamps. Returns `nil` when there is nothing usable.
    ///
    /// Supports multiple timestamps on one line (`[00:12.00][00:47.00]Chorus`)
    /// and ignores ID-tag lines like `[ar:Artist]` / `[ti:Title]`.
    public init?(lrc: String) {
        let trimmed = lrc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var parsed: [LyricLine] = []
        var sawTimestamp = false

        for raw in trimmed.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let (stamps, text) = Self.parseLRCLine(line)
            if stamps.isEmpty {
                // A non-timestamped, non-tag line — keep as plain text.
                if !Self.isMetadataTag(line) {
                    parsed.append(LyricLine(text: line))
                }
            } else {
                sawTimestamp = true
                for stamp in stamps {
                    parsed.append(LyricLine(text: text, start: stamp))
                }
            }
        }

        guard !parsed.isEmpty else { return nil }
        if sawTimestamp {
            parsed.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        self.init(lines: parsed)
    }

    /// Returns the timestamps found at the head of an LRC line plus the remaining
    /// text. `[01:02.50][01:30]Hello` → ([62.5, 90], "Hello").
    private static func parseLRCLine(_ line: String) -> (stamps: [TimeInterval], text: String) {
        var stamps: [TimeInterval] = []
        var rest = Substring(line)
        while rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { break }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            if let seconds = parseLRCTimestamp(String(inner)) {
                stamps.append(seconds)
            } else {
                // A `[tag:value]` (not a timestamp) — stop scanning timestamps.
                break
            }
            rest = rest[rest.index(after: close)...]
        }
        return (stamps, String(rest).trimmingCharacters(in: .whitespaces))
    }

    /// Parses `mm:ss`, `mm:ss.xx`, or `hh:mm:ss.xx` into seconds. Returns `nil`
    /// for non-timestamp brackets (e.g. `ar:Artist`).
    private static func parseLRCTimestamp(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.allSatisfy({ Double($0.replacingOccurrences(of: ",", with: ".")) != nil }) else { return nil }
        let values = parts.map { Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        switch values.count {
        case 2: return values[0] * 60 + values[1]
        case 3: return values[0] * 3600 + values[1] * 60 + values[2]
        default: return nil
        }
    }

    /// Whether a bracketed line is an LRC ID tag (`[ar:...]`, `[ti:...]`, etc.)
    /// rather than lyric content.
    private static func isMetadataTag(_ line: String) -> Bool {
        guard line.first == "[", line.last == "]" else { return false }
        let inner = line.dropFirst().dropLast()
        guard let colon = inner.firstIndex(of: ":") else { return false }
        let key = inner[inner.startIndex..<colon]
        return key.allSatisfy { $0.isLetter }
    }
}
