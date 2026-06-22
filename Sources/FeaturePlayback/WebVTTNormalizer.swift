import Foundation

/// Normalises subtitle text to WebVTT, which is the only timed-text format
/// `AVPlayer` accepts for an HLS subtitle rendition.
///
/// Jellyfin already serves WebVTT (returned unchanged); Plex sidecar streams
/// return SubRip (SRT), which differs only in its header and the `,` vs `.`
/// millisecond separator. Pure + platform-neutral so it can be unit tested.
public enum WebVTTNormalizer {
    /// Converts `text` to WebVTT. Already-WebVTT input is returned with only
    /// line endings normalised; SRT input is converted; anything else is wrapped
    /// in a WEBVTT header as a best effort.
    public static func normalize(_ text: String) -> String {
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmedLeading = unified.drop(while: { $0 == "\u{FEFF}" || $0 == "\n" || $0 == " " })

        if trimmedLeading.hasPrefix("WEBVTT") {
            return unified
        }
        return convertSRT(unified)
    }

    /// Converts SubRip to WebVTT: prepend the required header and rewrite cue
    /// timing lines (`00:00:01,000 --> 00:00:04,000` → `.` separators). Numeric
    /// SRT counters are left in place — WebVTT treats them as harmless cue ids.
    private static func convertSRT(_ srt: String) -> String {
        let converted = srt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                line.contains("-->") ? rewriteTimingLine(String(line)) : String(line)
            }
            .joined(separator: "\n")
        return "WEBVTT\n\n" + converted
    }

    /// Replaces the millisecond comma separator with a period in a cue timing
    /// line, leaving any trailing cue settings untouched.
    private static func rewriteTimingLine(_ line: String) -> String {
        var result = ""
        result.reserveCapacity(line.count)
        let chars = Array(line)
        for (i, ch) in chars.enumerated() {
            if ch == "," ,
               i > 0, chars[i - 1].isNumber,
               i + 1 < chars.count, chars[i + 1].isNumber {
                result.append(".")
            } else {
                result.append(ch)
            }
        }
        return result
    }
}
