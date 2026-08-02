#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// The corner mark a card wears when the title behind it **isn't in your
/// library** — an external credit surfaced from TMDb/Wikidata/TVmaze on a
/// person's page or in the in-player cast panel.
///
/// Two meanings, deliberately distinct, because they land on different people:
///
/// - ``notInLibrary`` is purely informational. Most viewers will never run
///   Seerr, so for them an unowned title is simply not actionable, and the mark
///   only has to answer "why can't I play this?" before they select it.
/// - ``requestable`` is an affordance, shown only while Seerr is connected: the
///   title isn't yours *yet* and you can ask for it.
///
/// Both sit in the artwork's **top-trailing** corner — the watch-status slot,
/// which is free here rather than contested: watch state cannot apply to a title
/// you don't have (you have neither watched it nor left it unwatched), so an
/// unowned card shows this instead of a check or an unwatched flag.
public enum MediaLibraryMark: Equatable, Sendable {
    /// Not in your library, and nothing you can do about it from here.
    case notInLibrary
    /// Not in your library, but Seerr is connected so it can be requested.
    case requestable

    /// Chosen from the on-device comparison screen, over ~22 alternatives.
    ///
    /// Binoculars for the informational case: the external-arrow idiom Apple uses
    /// (`arrow.up.forward`) promises the title opens somewhere else and it does
    /// not — it opens inside Plozz; a cloud reads as "streaming" rather than "not
    /// held"; and `eye.slash` / `minus.circle` / `nosign` all read as
    /// prohibitions or actions. Binoculars say "something to look at that isn't
    /// here", and the silhouette survives the 25pt the in-player card gives it.
    ///
    /// The filled plus keeps continuity with the Request button's `plus.circle`
    /// while gaining a disc, because the outline's ring is the first thing to go
    /// at 25pt.
    var systemImage: String {  // l10n:content — SF Symbol name, not copy
        switch self {
        case .notInLibrary: return "binoculars.fill"
        case .requestable: return "plus.circle.fill"
        }
    }

    public var accessibilityLabel: LocalizedStringResource {
        switch self {
        case .notInLibrary:
            return LocalizedStringResource(
                "libraryMark.notInLibrary",
                defaultValue: "Not in your library",
                comment: """
                    Accessibility label for the corner mark on a poster whose title \
                    the viewer does not own. Describes a state, not a command.
                    """
            )
        case .requestable:
            return LocalizedStringResource(
                "libraryMark.requestable",
                defaultValue: "Not in your library — can be requested",
                comment: """
                    Accessibility label for the corner mark on a poster whose title \
                    the viewer does not own but can request through Seerr. Describes \
                    a state; selecting the card opens the title, it does not request it.
                    """
            )
        }
    }

    /// The mark for an item, or `nil` when it's an ordinary library title.
    ///
    /// `seerConnected` only ever *upgrades* the informational mark to the
    /// actionable one — a title you don't own is still worth flagging when Seerr
    /// is absent, which is the majority case and the reason this exists.
    public static func mark(for item: MediaItem, seerConnected: Bool) -> MediaLibraryMark? {
        // One shared ownership answer (`TitleClassifier`), so a poster's mark can
        // never contradict the page it opens.
        guard TitleClassifier.isNotOwnedForBadge(item) else {
            return nil
        }
        return seerConnected ? .requestable : .notInLibrary
    }
}

/// Paints a ``MediaLibraryMark`` on artwork.
///
/// A bare glyph — no chip, no ring, no material plate. Legibility comes from
/// ``MediaArtworkChromeScrim``, the same gradient Continue Watching cards already
/// put under their chrome, which the host card draws; anything else stacked on
/// top makes the mark read as a sticker sitting on the artwork rather than part
/// of the card. For the same reason it carries no drop shadow.
///
/// Rendered `.palette` rather than `.hierarchical`, with both layers named. The
/// two symbols are white shapes on a white secondary layer (the plus's disc, the
/// binoculars' body), and hierarchical separates them only by an alpha gap it
/// picks itself — about half, which is transparent enough that artwork bleeds
/// through and unstable enough that the mark changes tone from poster to poster.
/// Naming that second layer as a **fixed grey** fixes both: the tone stays put
/// across artwork, and because the layer is now darker than the glyph rather than
/// the same white, it no longer competes with it.
public struct MediaLibraryMarkView: View {
    private let mark: MediaLibraryMark
    private let size: CGFloat

    /// Grey 50% at 70% opacity, chosen on-device from a 10-grey × 7-alpha matrix
    /// rendered at the in-player card's real size. Light enough to sit in the
    /// artwork, dark enough that the white glyph stays crisp on top of it.
    private static let secondaryLayer = Color(white: 0.5).opacity(0.7)

    public init(mark: MediaLibraryMark, size: CGFloat) {
        self.mark = mark
        self.size = size
    }

    public var body: some View {
        Image(systemName: mark.systemImage)
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Self.secondaryLayer)
            .accessibilityLabel(Text(mark.accessibilityLabel))
    }

    /// One rule for the mark's size on any card: the watched badge's share of a
    /// standard poster (42 ÷ 280 = 15%) applied to the card's real width.
    ///
    /// A fixed point size can't work across both places this appears — the
    /// in-player cast poster is 167pt wide against the person page's 280 — so a
    /// mark comfortable on one would dominate the other. A ratio keeps its
    /// optical weight steady instead.
    public static func size(forCardWidth width: CGFloat) -> CGFloat {
        (width * (PlozzTheme.Metrics.watchedBadgeSize / PlozzTheme.Metrics.posterWidth)).rounded()
    }
}
#endif
