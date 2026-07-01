import Foundation

/// The user-selectable subtitle typeface.
///
/// We default to **Atkinson Hyperlegible** — an SIL OFL font from the Braille
/// Institute engineered for legibility and character disambiguation (I/l/1, 0/O),
/// which is exactly what captions viewed from a couch need. It is bundled with the
/// app (Latin glyphs only); the renderer cascades to the tvOS system CJK fonts for
/// Japanese/Korean/Chinese so mixed-language and dual-subtitle lines still render.
/// `system` falls back to SF (no bundle). The enum is deliberately small and
/// additive — more bundled faces (e.g. a neutral grotesque) can be appended.
public enum SubtitleFontFamily: String, Codable, Sendable, Equatable, CaseIterable {
    case atkinson
    case system

    public var displayName: String {
        switch self {
        case .atkinson: return "Atkinson Hyperlegible"
        case .system: return "System (SF)"
        }
    }

    /// The PostScript family stem of the bundled face, or `nil` to use the system
    /// font. The renderer appends the weight/slant suffix (`-Regular`/`-Bold`/
    /// `-Italic`/`-BoldItalic`).
    public var postScriptStem: String? {
        switch self {
        case .atkinson: return "AtkinsonHyperlegible"
        case .system: return nil
        }
    }
}


/// This is the style model for Plozz's owned subtitle renderer and the persisted
/// source of truth for subtitle appearance. It covers every knob the product
/// brief calls for: size, position, offset, colour, overall opacity, an
/// HDR-luminance control, a background box, an edge (shadow) treatment and an
/// explicit border — each with adjustable colour, opacity and thickness where it
/// applies — plus an optional secondary style for dual subtitles.
///
/// It ships a tolerant `Codable` and is persisted via `SubtitleStyleStore`. A
/// profile's previously-saved look carries over from the retired `CaptionSettings`
/// via ``init(from:)`` (the decode-only `LegacyCaptionSettings` shim) during the
/// one-time migration.
///
/// Lives in `CoreModels` (dependency-free) so the renderer, the settings UI and
/// the future policy engine all share one definition.
public struct SubtitleStyle: Codable, Equatable, Sendable {

    // Reuse the shared, neutral colour and edge primitives so there is exactly
    // one colour type and one edge vocabulary across behaviour, style and policy.
    public typealias Color = SubtitleColor
    public typealias EdgeStyle = SubtitleEdgeStyle

    // MARK: Size & placement

    /// The subtitle typeface. Defaults to bundled Atkinson Hyperlegible.
    public var fontFamily: SubtitleFontFamily
    /// Multiplier on the base caption size (1.0 == default).
    public var fontScale: Double
    /// Vertical seat of the subtitle block, `0` = bottom safe edge … `1` = top.
    /// Default sits just above the bottom safe area.
    public var verticalPosition: Double
    /// Horizontal nudge, `-1` … `1` (0 = centred). Lets users dodge burned-in
    /// signage or letterbox furniture.
    public var horizontalOffset: Double

    // MARK: Colour & opacity

    /// Fill colour of the glyphs (its own alpha is respected).
    public var textColor: Color
    /// Master opacity applied to the **whole** subtitle (text + background +
    /// edge + border). A separate axis from colour and from HDR luminance.
    public var opacity: Double

    // MARK: HDR luminance

    /// Luminance scale applied **only when the video frame is HDR**, `0.2 … 1.0`.
    /// `1.0` (default) renders at SDR reference white — which on an HDR display
    /// the system already maps to a comfortable ~100–203 nits, so subtitles do
    /// not glare. Lowering it dims the white point further for very dark rooms.
    ///
    /// Pushing *brighter than* reference white requires an EDR rendering path and
    /// is a documented future extension; the control is modelled here so the UI
    /// and persistence are ready when that lands.
    public var hdrLuminanceScale: Double

    // MARK: Background box

    public struct Background: Codable, Equatable, Sendable {
        public var isEnabled: Bool
        public var color: Color          // colour + opacity via its alpha
        public var cornerRadius: Double
        /// Padding around the text, in points at 1.0 font scale.
        public var horizontalPadding: Double
        public var verticalPadding: Double

        public init(
            isEnabled: Bool = true,
            color: Color = Color(red: 0, green: 0, blue: 0, alpha: 0.5),
            cornerRadius: Double = 8,
            horizontalPadding: Double = 14,
            verticalPadding: Double = 6
        ) {
            self.isEnabled = isEnabled
            self.color = color
            self.cornerRadius = cornerRadius
            self.horizontalPadding = horizontalPadding
            self.verticalPadding = verticalPadding
        }
    }
    public var background: Background

    // MARK: Edge (shadow / raised / depressed / outline glow)

    public struct Edge: Codable, Equatable, Sendable {
        public var style: EdgeStyle
        public var color: Color
        /// Edge weight in points (drop-shadow radius / outline width).
        public var thickness: Double

        public init(
            style: EdgeStyle = .dropShadow,
            color: Color = Color(red: 0, green: 0, blue: 0, alpha: 0.9),
            thickness: Double = 2
        ) {
            self.style = style
            self.color = color
            self.thickness = thickness
        }
    }
    public var edge: Edge

    // MARK: Border (explicit glyph outline, independent of `edge`)

    public struct Border: Codable, Equatable, Sendable {
        public var isEnabled: Bool
        public var color: Color
        public var width: Double

        public init(
            isEnabled: Bool = false,
            color: Color = .black,
            width: Double = 1
        ) {
            self.isEnabled = isEnabled
            self.color = color
            self.width = width
        }
    }
    public var border: Border

    // MARK: Dual subtitles (secondary track)

    public struct Secondary: Codable, Equatable, Sendable {
        public enum Placement: String, Codable, Sendable, CaseIterable {
            case below, above
        }
        public var placement: Placement
        /// When `false` (default) the secondary line shares the **primary** look
        /// — same colour and size — so dual subtitles read as one cohesive
        /// system. Flip it on to visually distinguish the second language (handy
        /// for learning) via the overrides below.
        public var differentiate: Bool
        /// Secondary size relative to the primary — applied only when
        /// ``differentiate`` is on (e.g. 0.85 = a touch smaller).
        public var relativeScale: Double
        /// Secondary fill colour — applied only when ``differentiate`` is on.
        public var textColor: Color
        /// Gap between primary and secondary blocks, in points.
        public var gap: Double

        public init(
            placement: Placement = .above,
            differentiate: Bool = false,
            relativeScale: Double = 0.85,
            textColor: Color = Color(red: 0.85, green: 0.92, blue: 1.0),
            gap: Double = 6
        ) {
            self.placement = placement
            self.differentiate = differentiate
            self.relativeScale = relativeScale
            self.textColor = textColor
            self.gap = gap
        }
    }
    /// Style for a second simultaneous subtitle stream (e.g. a learner's native
    /// language). `nil` = dual subtitles off.
    public var secondary: Secondary?

    // MARK: Behaviour

    /// When true, defer entirely to the system/Settings caption style (no
    /// in-app style overrides are applied).
    public var followsSystemStyle: Bool

    public init(
        fontFamily: SubtitleFontFamily = .atkinson,
        fontScale: Double = 1.0,
        verticalPosition: Double = 0.06,
        horizontalOffset: Double = 0,
        textColor: Color = .white,
        opacity: Double = 1.0,
        hdrLuminanceScale: Double = 1.0,
        background: Background = Background(),
        edge: Edge = Edge(),
        border: Border = Border(),
        secondary: Secondary? = nil,
        followsSystemStyle: Bool = false
    ) {
        self.fontFamily = fontFamily
        self.fontScale = fontScale
        self.verticalPosition = verticalPosition
        self.horizontalOffset = horizontalOffset
        self.textColor = textColor
        self.opacity = opacity
        self.hdrLuminanceScale = hdrLuminanceScale
        self.background = background
        self.edge = edge
        self.border = border
        self.secondary = secondary
        self.followsSystemStyle = followsSystemStyle
    }

    /// The curated default look: white Atkinson with a **true outer outline** and
    /// a soft drop shadow, no background box — the modern, clean, highly-legible
    /// baseline. Users can switch on the box (one toggle) for the BBC/high-contrast
    /// style. The outline width is in points at the base size and the renderer
    /// scales it with the font, landing at roughly 5–6% of the glyph height as the
    /// subtitle-rendering research recommends.
    public static let `default` = SubtitleStyle(
        background: Background(isEnabled: false),
        edge: Edge(style: .dropShadow, color: Color(red: 0, green: 0, blue: 0, alpha: 0.75), thickness: 2.5),
        border: Border(isEnabled: true, color: .black, width: 2.5)
    )
}

// MARK: - Per-content-type resolution seam

public extension SubtitleStyle {
    /// The appearance to use for a given content category. Today appearance is a
    /// single global base, so this returns `self` for every category — but it is
    /// the resolution seam the renderer/policy call through, so adding a
    /// `[SubtitleContentCategory: SubtitleStyle]` overrides map later (in
    /// `SubtitleStyleStore`) is a drop-in with zero call-site churn.
    func style(for category: SubtitleContentCategory) -> SubtitleStyle {
        self
    }
}

// MARK: - Migration from the retired CaptionSettings

public extension SubtitleStyle {
    /// Build appearance from a decoded legacy `CaptionSettings` blob so a
    /// profile's previously-saved look (size / colour / background / edge / follow
    /// system) carries over into the new persisted style store.
    init(from legacy: LegacyCaptionSettings) {
        self.init(
            fontScale: legacy.fontScale,
            textColor: legacy.textColor,
            background: Background(
                isEnabled: legacy.backgroundColor.alpha > 0.001,
                color: legacy.backgroundColor
            ),
            edge: Edge(style: legacy.edgeStyle),
            followsSystemStyle: legacy.followsSystemStyle
        )
    }
}

// MARK: - Presets

public extension SubtitleStyle {
    struct Preset: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let style: SubtitleStyle
    }

    /// A small, opinionated set of starting points. Users tweak from here.
    static let presets: [Preset] = [
        Preset(id: "clean", name: "Clean", style: SubtitleStyle(
            background: Background(isEnabled: false),
            edge: Edge(style: .dropShadow, thickness: 3)
        )),
        Preset(id: "boxed", name: "Boxed", style: SubtitleStyle(
            background: Background(isEnabled: true,
                                   color: Color(red: 0, green: 0, blue: 0, alpha: 0.65)),
            edge: Edge(style: .none, thickness: 0)
        )),
        Preset(id: "outline", name: "Outline", style: SubtitleStyle(
            background: Background(isEnabled: false),
            edge: Edge(style: .uniform, thickness: 2),
            border: Border(isEnabled: true, color: .black, width: 1.5)
        )),
        Preset(id: "classic-yellow", name: "Classic Yellow", style: SubtitleStyle(
            textColor: .yellow,
            background: Background(isEnabled: false),
            edge: Edge(style: .dropShadow, thickness: 3)
        ))
    ]
}

// MARK: - Tolerant decoding (persist-ready, forward-compatible)

extension SubtitleStyle {
    private enum CodingKeys: String, CodingKey {
        case fontFamily, fontScale, verticalPosition, horizontalOffset
        case textColor, opacity, hdrLuminanceScale
        case background, edge, border, secondary, followsSystemStyle
    }

    /// Custom decoder so a style persisted by an older build (missing keys added
    /// later) still decodes, each unknown key falling back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SubtitleStyle.default
        self.init(
            fontFamily: try c.decodeIfPresent(SubtitleFontFamily.self, forKey: .fontFamily) ?? d.fontFamily,
            fontScale: try c.decodeIfPresent(Double.self, forKey: .fontScale) ?? d.fontScale,
            verticalPosition: try c.decodeIfPresent(Double.self, forKey: .verticalPosition) ?? d.verticalPosition,
            horizontalOffset: try c.decodeIfPresent(Double.self, forKey: .horizontalOffset) ?? d.horizontalOffset,
            textColor: try c.decodeIfPresent(Color.self, forKey: .textColor) ?? d.textColor,
            opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity,
            hdrLuminanceScale: try c.decodeIfPresent(Double.self, forKey: .hdrLuminanceScale) ?? d.hdrLuminanceScale,
            background: try c.decodeIfPresent(Background.self, forKey: .background) ?? d.background,
            edge: try c.decodeIfPresent(Edge.self, forKey: .edge) ?? d.edge,
            border: try c.decodeIfPresent(Border.self, forKey: .border) ?? d.border,
            secondary: try c.decodeIfPresent(Secondary.self, forKey: .secondary),
            followsSystemStyle: try c.decodeIfPresent(Bool.self, forKey: .followsSystemStyle) ?? d.followsSystemStyle
        )
    }
}
