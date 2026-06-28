import Foundation

// MARK: - Warmth

/// How warm (toward red) the picture is tinted. This is the *color* axis only —
/// it's independent of Dimness. Painted as a separate translucent warm layer
/// over the (already-dimmed) picture, so picking a warmer setting shifts the hue
/// without changing how dim the screen is. `none` skips the warm layer entirely
/// for people who only want a dimmer, neutral screen.
///
/// Discrete levels rather than a slider because pills are the tvOS-native,
/// remote-friendly idiom (raw sliders are awkward on the Siri Remote).
public enum NightShiftWarmth: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case light
    case warm
    case warmer
    case warmest
    case onFire

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .light: return "Kinda Warm"
        case .warm: return "Warm"
        case .warmer: return "Toasty"
        case .warmest: return "Roasting"
        case .onFire: return "On Fire"
        }
    }

    /// Strength of the warm tint at the deepest point of night — how far the
    /// green/blue channels are scaled down by the multiply. Higher = deeper, more
    /// saturated.
    public var peakOpacity: Double {
        switch self {
        case .none: return 0.0
        case .light: return 0.30
        case .warm: return 0.55
        case .warmer: return 0.80
        case .warmest: return 0.95
        case .onFire: return 1.0
        }
    }

    /// How aggressively green is pulled down relative to blue — i.e. the **hue**.
    /// Blue is always killed fully (`×(1−warm)`); green is killed at this fraction
    /// of that rate. A low value keeps lots of green → **orange/amber**; a high
    /// value strips green too → **red**. So the scale rides orange → orange-red →
    /// near-pure-red as you climb the levels.
    public var greenKill: Double {
        switch self {
        case .none: return 0.0
        case .light: return 0.50
        case .warm: return 0.50
        case .warmer: return 0.65
        case .warmest: return 0.70
        case .onFire: return 1.0
        }
    }
}

// MARK: - Dimness

/// How much the screen is dimmed — the *brightness* axis, independent of Warmth.
/// Painted as a translucent **black** layer, which works like sunglasses
/// (`result ≈ content × (1 − amount)`): it pulls down the bright parts of the
/// picture while leaving black essentially black, so dark theme doesn't light up.
/// This is the closest thing to a real brightness reduction available on tvOS,
/// which exposes no backlight/brightness API to apps.
public enum NightShiftDimness: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case subtle
    case medium
    case strong
    case intense
    case max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .subtle: return "Low"
        case .medium: return "Sorta Dark"
        case .strong: return "Dark"
        case .intense: return "Squinting"
        case .max: return "Can't See"
        }
    }

    /// Peak black-layer opacity at the deepest point of night.
    public var peakOpacity: Double {
        switch self {
        case .none: return 0.0
        case .subtle: return 0.38
        case .medium: return 0.55
        case .strong: return 0.72
        case .intense: return 0.84
        case .max: return 0.90
        }
    }
}

// MARK: - Schedule mode

/// How the on/off schedule is decided. `solar` follows the chosen region's
/// sunset/sunrise; `manual` uses two fixed clock times the viewer picks, in the
/// device's local time zone.
public enum NightShiftScheduleMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case solar
    case manual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .solar: return "Auto"
        case .manual: return "Manual"
        }
    }
}

// MARK: - Channel scalars

/// The per-channel multiply scalars (each `0...1`) the overlay multiplies the
/// whole app by. Kept as plain `Double`s here (no `SwiftUI.Color`) so `CoreModels`
/// stays Foundation-only; the UI layer turns these into a `Color`.
///
/// Multiplying scales each channel of the content *down* and never adds light, so
/// black stays black (unlike source-over, which lifts darks toward the tint and
/// looks bright). This mirrors the system Color Filters.
///
/// - Red is kept (only scaled by dimness), so the picture warms by losing
///   green/blue, not by gaining red.
/// - Blue is killed quickly with warmth (a warm screen has no blue).
/// - Green is killed at the level's `greenKill` fraction of the blue rate, so the
///   leftover green is what reads as **orange/amber**.
/// - Daytime (both 0) resolves to white → ×1 → no change.
public struct NightShiftChannelScalars: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let identity = NightShiftChannelScalars(red: 1, green: 1, blue: 1)
}
