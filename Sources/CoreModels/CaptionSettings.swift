import Foundation

/// User-customisable caption/subtitle appearance (pure data model).
///
/// The spec calls out "full customization of captions". This lives in
/// `CoreModels` so the Settings screen can edit it without importing
/// AVFoundation; `FeaturePlayback` adds an extension that converts it into
/// `AVTextStyleRule`s applied to the player.
public struct CaptionSettings: Codable, Equatable, Sendable {
    public enum EdgeStyle: String, Codable, CaseIterable, Sendable {
        case none, dropShadow, raised, depressed, uniform

        public var displayName: String {
            switch self {
            case .none: return "None"
            case .dropShadow: return "Drop Shadow"
            case .raised: return "Raised"
            case .depressed: return "Depressed"
            case .uniform: return "Outline"
            }
        }
    }

    /// An RGBA colour stored in a `Codable`, platform-neutral way (`0...1`).
    public struct RGBAColor: Codable, Equatable, Sendable, Hashable {
        public var red, green, blue, alpha: Double
        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }
        public static let white = RGBAColor(red: 1, green: 1, blue: 1)
        public static let black = RGBAColor(red: 0, green: 0, blue: 0)
        public static let yellow = RGBAColor(red: 1, green: 0.85, blue: 0)
        public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)

        public static let presets: [(name: String, color: RGBAColor)] = [
            ("White", .white),
            ("Yellow", .yellow),
            ("Black", .black)
        ]
    }

    /// Multiplier applied to caption font size (1.0 == default).
    public var fontScale: Double
    public var textColor: RGBAColor
    public var backgroundColor: RGBAColor
    public var edgeStyle: EdgeStyle
    /// When true, Plizz defers entirely to the system/Settings caption style.
    public var followsSystemStyle: Bool

    public init(
        fontScale: Double = 1.0,
        textColor: RGBAColor = .white,
        backgroundColor: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5),
        edgeStyle: EdgeStyle = .dropShadow,
        followsSystemStyle: Bool = true
    ) {
        self.fontScale = fontScale
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.edgeStyle = edgeStyle
        self.followsSystemStyle = followsSystemStyle
    }

    public static let `default` = CaptionSettings()
}
