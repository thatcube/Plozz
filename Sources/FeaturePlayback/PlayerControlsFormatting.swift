import CoreModels
import Foundation

/// Pure label/formatting helpers extracted from `PlayerControls`' subtitle style
/// editor. These turn raw style values (percent positions, corner radii, preset
/// colors, edge state) into the short human-readable strings the row UI shows.
/// No SwiftUI, no view state — just value → string mappings — so each rule is
/// directly unit-testable.
enum PlayerControlsFormatting {
    /// Sentinel top step for corner radius that reads as a full capsule/pill.
    static let cornerFull = 400

    /// Index of the option nearest `value` (used to snap a raw style value onto
    /// the discrete option grid). `0` for an empty option set.
    static func nearestIndex(_ options: [Int], _ value: Int) -> Int {
        guard !options.isEmpty else { return 0 }
        var best = 0, bestDelta = Int.max
        for (i, option) in options.enumerated() {
            let delta = abs(option - value)
            if delta < bestDelta { bestDelta = delta; best = i }
        }
        return best
    }

    /// 0% = seated at the bottom safe edge; 90% = near the top. Anchors are named
    /// so the extremes read clearly, but every step in between is a plain percent.
    static func positionLabel(_ pct: Int) -> String {
        switch pct {
        case 0: return "Bottom"
        case 90: return "Top"
        default: return "\(pct)%"
        }
    }

    /// Horizontal offset readout: 0 reads "Centre"; a signed percentage otherwise,
    /// worded by direction so the sign never has to be parsed.
    static func hOffsetLabel(_ pct: Int) -> String {
        if pct == 0 { return "Centre" }
        return pct > 0 ? "Right \(pct)%" : "Left \(-pct)%"
    }

    /// Corner radius readout: the sentinel top step reads "Full" (a capsule/pill);
    /// every other step is its point value.
    static func cornerLabel(_ pts: Int) -> String {
        pts >= cornerFull ? "Full" : "\(pts)"
    }

    /// Matches the preset palette by RGB (ignoring alpha), so a swatch reads by name
    /// even when its opacity has been dialled down elsewhere.
    static func colorLabel(_ color: SubtitleColor) -> String {
        SubtitleColor.presets.first(where: { $0.color.red == color.red && $0.color.green == color.green && $0.color.blue == color.blue })?.name ?? "Custom"
    }

    /// Compact summary for the "Shadow & Outline" submenu row. The row title
    /// already says "Shadow & Outline", so echoing "Shadow + Outline" as the value
    /// reads as repetitive — collapse to "On" when both effects are active, name
    /// the single active one otherwise, and "Off" when neither is on.
    static func edgeSummary(_ s: SubtitleStyle) -> String {
        let shadow = s.edge.style != .none
        let outline = s.border.isEnabled
        switch (shadow, outline) {
        case (true, true): return "On"
        case (true, false): return "Shadow"
        case (false, true): return "Outline"
        case (false, false): return "Off"
        }
    }

    static func boxColorLabel(_ color: SubtitleColor) -> String {
        if color.red == 0, color.green == 0, color.blue == 0 { return "Black" }
        if color.red == 1, color.green == 1, color.blue == 1 { return "White" }
        if color.red == 0.15, color.green == 0.15, color.blue == 0.15 { return "Charcoal" }
        return "Custom"
    }
}
