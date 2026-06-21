#if canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreMedia
import CoreModels

/// Converts the platform-neutral `CaptionSettings` into AVFoundation styling.
extension CaptionSettings {
    /// Builds `AVTextStyleRule`s to apply to an `AVPlayerItem`.
    /// Returns `nil` when following the system style (no overrides).
    public func textStyleRules() -> [AVTextStyleRule]? {
        guard !followsSystemStyle else { return nil }

        var styles: [String: Any] = [:]
        styles[kCMTextMarkupAttribute_ForegroundColorARGB as String] = textColor.argbArray
        styles[kCMTextMarkupAttribute_BackgroundColorARGB as String] = backgroundColor.argbArray
        styles[kCMTextMarkupAttribute_BaseFontSizePercentageRelativeToVideoHeight as String] =
            max(1.0, 5.0 * fontScale)
        styles[kCMTextMarkupAttribute_CharacterEdgeStyle as String] = edgeStyle.cmEdgeStyle

        guard let rule = AVTextStyleRule(textMarkupAttributes: styles) else { return nil }
        return [rule]
    }
}

private extension CaptionSettings.RGBAColor {
    /// Core Media expects `[alpha, red, green, blue]` doubles in `0...1`.
    var argbArray: [Double] { [alpha, red, green, blue] }
}

private extension CaptionSettings.EdgeStyle {
    var cmEdgeStyle: String {
        switch self {
        case .none: return kCMTextMarkupCharacterEdgeStyle_None as String
        case .dropShadow: return kCMTextMarkupCharacterEdgeStyle_DropShadow as String
        case .raised: return kCMTextMarkupCharacterEdgeStyle_Raised as String
        case .depressed: return kCMTextMarkupCharacterEdgeStyle_Depressed as String
        case .uniform: return kCMTextMarkupCharacterEdgeStyle_Uniform as String
        }
    }
}

#endif
