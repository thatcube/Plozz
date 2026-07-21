import CoreModels
import Foundation

/// One trailer timeline shared by every hero surface on every platform.
public enum HeroTrailerTimeline {
    public static let leadIn: TimeInterval = 3

    public static func duration(
        autoAdvanceSeconds: Int,
        mode: HeroBackgroundMode,
        trailerDuration: TimeInterval
    ) -> TimeInterval {
        if mode == .trailer, trailerDuration > 0 {
            return leadIn + trailerDuration
        }
        return Double(autoAdvanceSeconds)
    }
}
