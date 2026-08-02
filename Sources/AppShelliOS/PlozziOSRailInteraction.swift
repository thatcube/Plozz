#if os(iOS)
import SwiftUI
import CoreModels

/// What pressing a card in a Home rail does.
///
/// Declared per rail rather than inferred from the card's shape. A landscape card
/// is a presentation choice; it is not a promise that the row is Continue
/// Watching, and reading behaviour off `isLandscape` meant any future landscape
/// rail would silently start playing things.
enum PlozziOSRailInteraction {
    /// Push the item's detail page. The default for browse rails.
    case openDetail
    /// Resume playback. Continue Watching only, matching tvOS, where pressing a
    /// resume card has always played rather than opening a page.
    case play
}

private struct PlozziOSRailPlayKey: EnvironmentKey {
    static let defaultValue: ((MediaItem) -> Void)? = nil
}

extension EnvironmentValues {
    /// Installed by the page that owns the player, so a rail can resume without
    /// knowing how playback is presented. Absent means "no player here" and cards
    /// fall back to opening detail rather than doing nothing.
    var plozziOSRailPlay: ((MediaItem) -> Void)? {
        get { self[PlozziOSRailPlayKey.self] }
        set { self[PlozziOSRailPlayKey.self] = newValue }
    }
}

extension View {
    func plozziOSRailPlay(_ play: ((MediaItem) -> Void)?) -> some View {
        environment(\.plozziOSRailPlay, play)
    }
}

extension MediaItem {
    /// Whether pressing this can start playback right now.
    ///
    /// A discovery/request stub is not in any library and has nothing to run, and
    /// a container resolves to many files rather than one. Both must open their
    /// detail page instead of being handed to the player.
    var isPlayableNow: Bool {
        // The same index-free answer the card's own corner mark uses, so a press can
        // never contradict what the poster is showing. Was a fifth hand-rolled copy of
        // this classification.
        guard !TitleClassifier.isNotOwnedForBadge(self),
              !isUpcomingUnaired else { return false }
        switch kind {
        case .movie, .episode, .video, .series: return true
        default: return false
        }
    }
}
#endif
