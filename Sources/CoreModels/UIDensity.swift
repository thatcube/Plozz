import Foundation

/// User-selectable UI density (pure data model).
///
/// A single knob that scales the whole media UI — card sizes, grid column
/// counts and the gaps between media — so a household can tune Plozz from a
/// tight power-user wall to a low-vision "extra large" layout. Persisted **per
/// profile** (each profile keeps its own density) like `AppTheme`; the concrete
/// point values it resolves to live in `CoreUI` (`PlozzMetrics`), so this stays
/// Foundation-only and the Settings screen can edit it without importing SwiftUI.
public enum UIDensity: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Tightest layout of all — the most columns, smallest cards and tightest
    /// gaps. For power users who want to pack the absolute maximum on screen.
    case micro
    /// Very tight — lots of columns, small cards, tight gaps.
    case extraCompact
    /// Tighter than the default — more columns, smaller cards, tighter gaps.
    case compact
    /// The default, balanced layout.
    case standard
    /// Roomier — fewer columns, larger cards, more breathing room.
    case spacious
    /// Largest layout — fewest columns, big cards. Tuned for low-vision viewers
    /// who need media to be large.
    case extraLarge

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .micro: return "Micro"
        case .extraCompact: return "Tiny"
        case .compact: return "Small"
        case .standard: return "Default"
        case .spacious: return "Large"
        case .extraLarge: return "Huge"
        }
    }

    /// Short helper line shown under each option in Settings.
    public var detail: String {
        switch self {
        case .micro: return "Most cards, smallest"
        case .extraCompact: return "More cards, smaller"
        case .compact: return "Slightly smaller"
        case .standard: return "Default size"
        case .spacious: return "Fewer cards, bigger"
        case .extraLarge: return "Fewest cards, biggest"
        }
    }

    /// SF Symbol shown next to the option in Settings. Reads as a coarse → fine
    /// "grid density" ramp (fewer, bigger cells → more, smaller cells).
    public var symbolName: String {
        switch self {
        case .micro: return "square.grid.4x3.fill"
        case .extraCompact: return "square.grid.3x3.fill"
        case .compact: return "square.grid.3x2.fill"
        case .standard: return "square.grid.2x2.fill"
        case .spacious: return "rectangle.grid.1x2.fill"
        case .extraLarge: return "square.fill"
        }
    }

    /// Multiplier applied to media card sizes and the gaps between them. `1.0`
    /// is standard density. Card artwork, inter-card spacing and vertical row
    /// rhythm all scale by this factor.
    public var scale: Double {
        switch self {
        case .micro: return 0.6
        case .extraCompact: return 0.72
        case .compact: return 0.85
        case .standard: return 1.0
        case .spacious: return 1.18
        case .extraLarge: return 1.4
        }
    }

    /// Number of columns in the shared dense poster "Browse" wall (library +
    /// search). Fewer columns means each flexible tile is wider, so this is the
    /// main lever that makes posters visibly bigger at higher densities.
    public var posterGridColumns: Int {
        switch self {
        case .micro: return 10
        case .extraCompact: return 9
        case .compact: return 8
        case .standard: return 7
        case .spacious: return 6
        case .extraLarge: return 5
        }
    }

    public static let `default`: UIDensity = .standard
}
