import Foundation

/// The complete, renderer-facing subtitle appearance model.
///
/// This is the **forward** style model for Plozz's owned subtitle renderer. It
/// is intentionally richer than the currently-persisted ``CaptionSettings`` and
/// covers every knob the product brief calls for: size, position, offset,
/// colour, overall opacity, an HDR-luminance control, a background box, an edge
/// (shadow) treatment and an explicit border — each with adjustable colour,
/// opacity and thickness where it applies — plus an optional secondary style for
/// dual subtitles.
///
/// ## Relationship to `CaptionSettings` (deliberately non-destructive)
/// `CaptionSettings` remains the persisted per-profile model **for now**. This
/// type bridges from it via ``init(from:)`` so existing user settings carry over,
/// and it ships its own tolerant `Codable` so it is *persist-ready* — but we do
/// not migrate persistence until the renderer is validated on-device. That
/// staging is intentional: prove the model + renderer first, then move the
/// source of truth, so a wrong early guess can't strand saved settings.
///
/// Lives in `CoreModels` (dependency-free) so the renderer, the settings UI and
/// the future policy engine all share one definition.
public struct SubtitleStyle: Codable, Equatable, Sendable {

    // Reuse the existing, already-persisted colour and edge primitives so there
    // is exactly one colour type and one edge vocabulary across the app.
    public typealias Color = CaptionSettings.RGBAColor
    public typealias EdgeStyle = CaptionSettings.EdgeStyle

    // MARK: Size & placement

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
        /// Secondary size relative to the primary (e.g. 0.85 = a touch smaller).
        public var relativeScale: Double
        public var textColor: Color
        /// Gap between primary and secondary blocks, in points.
        public var gap: Double

        public init(
            placement: Placement = .below,
            relativeScale: Double = 0.85,
            textColor: Color = Color(red: 0.85, green: 0.92, blue: 1.0),
            gap: Double = 6
        ) {
            self.placement = placement
            self.relativeScale = relativeScale
            self.textColor = textColor
            self.gap = gap
        }
    }
    /// Style for a second simultaneous subtitle stream (e.g. a learner's native
    /// language). `nil` = dual subtitles off.
    public var secondary: Secondary?

    // MARK: Behaviour

    /// When true, defer entirely to the system/Settings caption style (parity
    /// with `CaptionSettings.followsSystemStyle`).
    public var followsSystemStyle: Bool

    public init(
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

    public static let `default` = SubtitleStyle()
}

// MARK: - Bridge from the persisted CaptionSettings (non-destructive)

public extension SubtitleStyle {
    /// Build a forward style from the currently-persisted ``CaptionSettings`` so
    /// existing per-profile preferences are honoured before persistence migrates.
    init(from caption: CaptionSettings) {
        self.init(
            fontScale: caption.fontScale,
            textColor: caption.textColor,
            background: Background(
                isEnabled: caption.backgroundColor.alpha > 0.001,
                color: caption.backgroundColor
            ),
            edge: Edge(style: caption.edgeStyle),
            followsSystemStyle: caption.followsSystemStyle
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
        case fontScale, verticalPosition, horizontalOffset
        case textColor, opacity, hdrLuminanceScale
        case background, edge, border, secondary, followsSystemStyle
    }

    /// Custom decoder so a style persisted by an older build (missing keys added
    /// later) still decodes, each unknown key falling back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SubtitleStyle.default
        self.init(
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
