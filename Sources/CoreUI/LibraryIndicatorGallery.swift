#if DEBUG && canImport(SwiftUI)
import CoreModels
import MetadataKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Why this file exists
//
// Plozz now shows titles the viewer does not own — external credits in the
// in-player Cast tab and on the person page's "Known for" shelf — and nothing on
// a card says so. Two DIFFERENT meanings need marks:
//
//   1. "Not in your library" — purely informational, and the one that matters,
//      because most people will never install Seerr/Jellyseerr and for them an
//      unowned title is simply not actionable.
//   2. "You can request this" — actionable, only when Seerr is connected. Today
//      the request affordance is `plus.circle`.
//
// Nobody can judge a 42pt glyph from a symbol name in a diff, so this screen
// renders every plausible candidate at PRODUCTION SIZE, in isolation and
// composited onto real posters over pale and dark artwork, and lets the choice be
// made by looking at a TV from three metres.
//
// Two things it is deliberately strict about:
//
// - The mark is a BARE white glyph over the shared `MediaArtworkChromeScrim`,
//   the same gradient Continue Watching cards already put under their chrome. No
//   chip, no ring, no material plate — those read as stickers pasted on the art,
//   and the app has a token for exactly this job.
// - It renders both card footprints an unowned title actually appears at: the
//   person page's density-scaled poster, and the in-player cast credits poster,
//   which is a FIXED 167×250 (height = InfoPanelView.cardHeight − 2×24 = 250,
//   width = round(height × 2/3)). The small one is 60% the width, so a glyph
//   that is comfortable on the person page is a quarter of the width of the
//   player card. Judging on one size alone would have been misleading.
//
// The mark goes in the poster's TOP-RIGHT, the watch-status slot, and REPLACES
// what is there today. Watch state is meaningless for a title you do not own —
// you cannot have watched it, and you cannot not-have-watched it either — so the
// unwatched flag / watched check simply does not apply and the slot is free. That
// is why nothing on this screen moves the mark to another corner: there is no
// corner contest to resolve.
//
// Deliberately `#if DEBUG`: it is a design instrument, not a feature. It is
// reachable from Settings ▸ Help & Diagnostics in a Debug build only, so it can
// never reach TestFlight or the App Store, and none of its labels are app copy
// (every string here is `Text(verbatim:)` — symbol names and developer notes).
//
// Once an option is chosen this file and its Settings entry are deleted, and the
// winner is wired into `MediaCardPlaybackIndicators` (probably as a user-selectable
// enum next to `WatchStatusIndicator`, which is the direct precedent for both the
// corner position and the "let the user pick" shape).

// MARK: - Candidate model

/// One SF Symbol under consideration, with the reason it is in the running.
struct IndicatorGlyphCandidate: Identifiable {
    /// SF Symbol name. Doubles as the on-screen label and the identity.
    let symbol: String
    /// Why it is a candidate / what it risks saying — developer notes, shown
    /// under the swatch so the screen is self-explaining on the TV.
    let note: String

    var id: String { symbol }
}

enum IndicatorGalleryCandidates {
    /// "Not in your library". Grouped by the idiom each glyph borrows from,
    /// because the risk is semantic, not aesthetic: several of these are legible
    /// but say the wrong thing.
    static let notInLibrary: [IndicatorGlyphCandidate] = [
        // Apple's "external" idiom. Brandon flagged the tension himself: in the
        // Apple TV app this means "opens in another app", and we open nothing
        // externally — the title opens inside Plozz. Included for comparison.
        .init(symbol: "arrow.up.forward", note: "Apple external idiom. We open IN-app, so may mislead"),
        .init(symbol: "arrow.up.forward.app.fill", note: "Apple TV app's filled external badge"),
        .init(symbol: "arrow.up.right.square", note: "Same idiom, squarer"),
        // "Somewhere else / not held locally".
        .init(symbol: "cloud", note: "Elsewhere, not held. Reads thin at size"),
        .init(symbol: "cloud.fill", note: "Elsewhere, not held. Solid mass"),
        .init(symbol: "globe", note: "Out in the world. Busy interior"),
        // "Discoverable".
        .init(symbol: "sparkle.magnifyingglass", note: "Discovery. Two motifs in one glyph"),
        .init(symbol: "sparkles", note: "Discovery. No 'absence' meaning at all"),
        .init(symbol: "magnifyingglass", note: "Search/browse, not ownership"),
        .init(symbol: "binoculars.fill", note: "Scouting/looking ahead"),
        // "Unknown".
        .init(symbol: "questionmark.circle", note: "Unknown. Reads as an error to some"),
        .init(symbol: "questionmark.circle.fill", note: "Filled variant"),
        .init(symbol: "folder.badge.questionmark", note: "Unknown file. Very busy"),
        // "Outline = not filled in yet".
        .init(symbol: "circle.dashed", note: "Absent/placeholder. Quietest option"),
        .init(symbol: "square.dashed", note: "Absent/placeholder, squarer"),
        // Negations. Strong, but a negation reads as a prohibition.
        .init(symbol: "rectangle.on.rectangle.slash", note: "Not in the stack. Very busy at 42pt"),
        .init(symbol: "eye.slash", note: "Says 'hidden', which is not what we mean"),
        .init(symbol: "minus.circle", note: "Says 'remove', risks reading as an action"),
        .init(symbol: "nosign", note: "Prohibition. Almost certainly too hostile"),
        .init(symbol: "xmark.bin", note: "Deleted. Wrong meaning, kept for contrast"),
        // Library-shaped.
        .init(symbol: "books.vertical", note: "Literal 'library'. But marks the NOT case oddly"),
        .init(symbol: "tray", note: "Your holdings. Empty tray = not held")
    ]

    /// "You can request this" — only ever shown when Seerr is connected.
    static let request: [IndicatorGlyphCandidate] = [
        .init(symbol: "plus.circle", note: "What the Request button uses today"),
        .init(symbol: "plus.circle.fill", note: "Filled — more mass, more legible far away"),
        .init(symbol: "plus", note: "Bare plus, no ring"),
        .init(symbol: "arrow.down.circle", note: "'Get it' — download idiom"),
        .init(symbol: "arrow.down.circle.fill", note: "Filled download idiom"),
        .init(symbol: "square.and.arrow.down", note: "Save/get. Apple's download glyph"),
        .init(symbol: "square.and.arrow.down.fill", note: "Filled save/get"),
        .init(symbol: "tray.and.arrow.down.fill", note: "Into your library. Literal but busy"),
        .init(symbol: "paperplane.circle.fill", note: "'Send a request' — the ASK, not the getting"),
        .init(symbol: "bell.badge", note: "Notify me. Different promise from 'request'"),
        .init(symbol: "hand.raised.fill", note: "Asking. Reads as 'stop' to many"),
        .init(symbol: "plus.rectangle.on.rectangle", note: "Add to the stack"),
        .init(symbol: "cart.badge.plus", note: "Commerce framing — kept to reject deliberately")
    ]
}

// MARK: - The mark

/// A candidate glyph, drawn BARE — white, no chip, no ring — over the shared
/// artwork scrim. That is the treatment Continue Watching cards already use for
/// their chrome (`MediaArtworkChromeScrim`), so this reuses that exact gradient
/// rather than inventing a new plate: nothing on a poster should look like a
/// sticker pasted on the art.
///
/// The scrim is drawn by the poster tile (it has to span the card's full width),
/// not here, so this view is only ever the glyph itself.
struct IndicatorGlyphBadge: View {
    let symbol: String
    /// Optical size of the glyph. Scales with the card — a mark sized for a
    /// 280pt poster is a quarter of the width of a 167pt player-panel poster.
    var size: CGFloat = IndicatorCardSize.glyphSize(forCardWidth: PlozzTheme.Metrics.posterWidth)
    /// Alpha of the symbol's SECONDARY layer — for `plus.circle.fill`, the disc
    /// behind the plus. `nil` keeps plain `.hierarchical`.
    ///
    /// `.hierarchical` is the right look: the plus reading stronger than the disc
    /// is what gives the mark depth, and flattening it to `.monochrome` loses
    /// that. Its problem is only that it picks the secondary alpha itself, at
    /// roughly half, which is see-through enough that artwork shows through the
    /// disc. `.palette` draws the identical layer structure while letting the
    /// alpha be named — so this is hierarchical with the disc turned up, NOT a
    /// different rendering.
    ///
    /// Both layers are the SAME white on purpose. Raising alpha makes the disc
    /// more solid without making it brighter; lightening the colour instead would
    /// have made it glare.
    var discOpacity: Double?

    var body: some View {
        if IndicatorSymbolAvailability.exists(symbol) {
            glyph
                // Just enough to hold an edge where the scrim has already
                // thinned out. The scrim does the real work.
                .shadow(color: .black.opacity(0.5), radius: size * 0.14, y: size * 0.03)
        } else {
            // A missing symbol renders as nothing, which would silently look like
            // "this candidate is invisible". Say so instead.
            Text(verbatim: "!")
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(.white)
                .padding(size * 0.2)
                .background(Circle().fill(.red))
        }
    }

    @ViewBuilder
    private var glyph: some View {
        let image = Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
        if let discOpacity {
            image
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .white.opacity(discOpacity))
        } else {
            image
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
    }
}

/// The two marks that were chosen off this screen, so the pair has one place it
/// is defined rather than being spelled out at each use site.
enum ChosenIndicator {
    /// "Not in your library." Picked over the external-arrow idiom (which claims
    /// we open elsewhere — we don't), the cloud (says "streaming", not "not
    /// held") and the negations (`eye.slash`, `minus.circle`, `nosign`, which all
    /// read as prohibitions). Binoculars say "something to look at that isn't
    /// here", which is the actual meaning, and the silhouette survives 25pt on
    /// the player card.
    static let notInLibrary = "binoculars.fill"
    /// "You can request this", shown only while Seerr is connected. Kept the
    /// plus, gained the disc: the outline `plus.circle` the Request button uses
    /// loses its ring at player-card size.
    static let request = "plus.circle.fill"
    /// How opaque the request disc is. Hierarchical's own choice (about half) let
    /// the artwork through it; this is the same white, just turned up.
    static let requestDiscOpacity: Double = 0.85
}

/// SF Symbols vary by OS version, and an unknown name renders as an empty view.
/// On a screen whose whole job is "compare what these look like", a silently
/// blank candidate is worse than a missing one, so availability is checked once
/// and cached.
enum IndicatorSymbolAvailability {
    #if canImport(UIKit)
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]
    private static let lock = NSLock()

    static func exists(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[name] { return known }
        let known = UIImage(systemName: name) != nil
        cache[name] = known
        return known
    }
    #else
    static func exists(_ name: String) -> Bool { true }
    #endif
}

// MARK: - Non-glyph treatments

/// Whole-poster treatments that carry the "not in your library" meaning WITHOUT
/// an icon. These are in the running on equal footing: a dashed edge or a drained
/// poster may say "not held" more honestly than any glyph, and the corner is
/// already crowded by watch state.
enum IndicatorPosterTreatment: String, CaseIterable, Identifiable {
    case none
    case dashedBorder
    case desaturated
    case dimmed
    case desaturatedAndDimmed
    case textPillTopLeading
    case textPillBottom
    case neutralCornerRibbon
    case dashedBorderPlusPill

    var id: String { rawValue }

    var label: String {  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
        switch self {
        case .none: return "control — no treatment"
        case .dashedBorder: return "dashed poster border"
        case .desaturated: return "desaturated artwork"
        case .dimmed: return "dimmed artwork"
        case .desaturatedAndDimmed: return "desaturated + dimmed"
        case .textPillTopLeading: return "\"Not in library\" pill, top-leading"
        case .textPillBottom: return "\"Not in library\" pill, bottom"
        case .neutralCornerRibbon: return "grey corner ribbon (unwatched flag shape)"
        case .dashedBorderPlusPill: return "dashed border + pill"
        }
    }

    var note: String {  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
        switch self {
        case .none: return "Reference. Everything else is judged against this"
        case .dashedBorder: return "Reads at any distance; survives any artwork"
        case .desaturated: return "Honest 'drained', but colour posters lose identity"
        case .dimmed: return "Recedes in a row; can look like a loading state"
        case .desaturatedAndDimmed: return "Strongest 'not yours'; heaviest handed"
        case .textPillTopLeading: return "Unambiguous. Costs a translated string"
        case .textPillBottom: return "Same, but collides with the progress bar slot"
        case .neutralCornerRibbon: return "Sibling of the unwatched flag; fights it for the corner"
        case .dashedBorderPlusPill: return "Belt and braces — likely too much"
        }
    }
}

// MARK: - Artwork samples

/// The artwork a candidate has to survive. A glyph that reads on one of these can
/// disappear on the other, which is the entire reason both are on screen.
struct IndicatorArtworkSample: Identifiable, Hashable {
    let id: String
    let title: String  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
    let year: Int
    /// Synthetic stand-in drawn when the poster can't be resolved (no network, no
    /// TMDb key), so the screen is never blank.
    let fallbackTop: Color
    let fallbackBottom: Color

    static let pale = IndicatorArtworkSample(
        id: "pale",
        title: "The Grand Budapest Hotel",
        year: 2014,
        fallbackTop: Color(white: 0.96),
        fallbackBottom: Color(red: 0.90, green: 0.78, blue: 0.80)
    )

    static let dark = IndicatorArtworkSample(
        id: "dark",
        title: "The Dark Knight",
        year: 2008,
        fallbackTop: Color(white: 0.10),
        fallbackBottom: Color(white: 0.03)
    )

    static let all: [IndicatorArtworkSample] = [.pale, .dark]

    /// A minimal item purely for artwork resolution — title + year is all the
    /// poster lookup needs.
    var lookupItem: MediaItem {
        MediaItem(id: "indicator-gallery-\(id)", title: title, kind: .movie, productionYear: year)
    }
}

/// Resolves the two sample posters ONCE and shares the URLs with every tile, so a
/// screen with ~90 poster tiles issues two lookups rather than ninety.
@MainActor
@Observable
final class IndicatorArtworkStore {
    private(set) var urls: [String: URL] = [:]

    func load() async {
        for sample in IndicatorArtworkSample.all where urls[sample.id] == nil {
            if let url = await ArtworkRouter.shared.artworkURL(.poster, for: sample.lookupItem) {
                urls[sample.id] = url
            }
        }
    }
}

// MARK: - Card sizes

/// The two places an unowned title actually appears today, at their REAL
/// footprints. They differ enough that a mark judged on one says nothing about
/// the other: the player's cast poster is 60% the width of the person page's, so
/// a glyph sized for the big card eats a quarter of the small one.
enum IndicatorCardSize: String, CaseIterable, Identifiable {
    /// The person detail page's "Known for" shelves — `MediaRowView` →
    /// `PosterCardView(style: .poster)`, i.e. `metrics.posterWidth` (280 at
    /// standard density, and it moves with the Display Size setting).
    case personPage
    /// The in-player cast L2 credits row. Derived from the info card, NOT
    /// density-scaled: height = `InfoPanelView.cardHeight - contentPadding * 2`
    /// = 298 − 48 = 250, width = round(height × 2/3) = 167, and its corner radius
    /// is `playerPanelCornerRadius − contentPadding` = 18.
    case playerCast

    var id: String { rawValue }

    /// Card width. The person page tracks the live density metric; the player
    /// panel is a fixed geometry and does not.
    func width(metrics: PlozzMetrics) -> CGFloat {
        switch self {
        case .personPage: return metrics.posterWidth
        case .playerCast: return 167
        }
    }

    func height(metrics: PlozzMetrics) -> CGFloat {
        switch self {
        case .personPage: return metrics.posterHeight
        case .playerCast: return 250
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .personPage: return PlozzTheme.Metrics.posterArtCornerRadius
        case .playerCast: return PlozzTheme.Metrics.playerPanelCornerRadius - 24
        }
    }

    /// Card-edge inset for the mark, kept proportional so the small card doesn't
    /// end up with a mark jammed into its corner.
    func inset(metrics: PlozzMetrics) -> CGFloat {
        max(6, width(metrics: metrics) * 0.035)
    }

    var label: String {  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
        switch self {
        case .personPage: return "person page"
        case .playerCast: return "player cast"
        }
    }

    /// One rule for how big the glyph is on any card: the watched badge's share
    /// of a standard poster's width (42 / 280 = 15%), applied to whatever width
    /// this card actually has. Keeps the mark's optical weight constant instead
    /// of letting a fixed point size dominate the small card.
    static func glyphSize(forCardWidth width: CGFloat) -> CGFloat {
        (width * (PlozzTheme.Metrics.watchedBadgeSize / PlozzTheme.Metrics.posterWidth)).rounded()
    }
}

// MARK: - Poster tile

/// A poster at one of the two real footprints, carrying one candidate treatment.
/// Everything on this screen is judged on one of these, because a glyph in a
/// vacuum tells you nothing about whether it survives artwork.
struct IndicatorPosterTile: View {
    let sample: IndicatorArtworkSample
    var glyph: String?
    var size: IndicatorCardSize = .personPage
    /// See `IndicatorGlyphBadge.discOpacity`.
    var discOpacity: Double?
    /// Always the top-right — the watch-status slot, which is free for an unowned
    /// title because watch state cannot apply to something you don't have.
    private let alignment: Alignment = .topTrailing
    var treatment: IndicatorPosterTreatment = .none

    @Environment(\.plozzMetrics) private var metrics
    @Environment(IndicatorArtworkStore.self) private var artwork

    private var width: CGFloat { size.width(metrics: metrics) }
    private var height: CGFloat { size.height(metrics: metrics) }
    private var radius: CGFloat { size.cornerRadius }
    private var badgeInset: CGFloat { size.inset(metrics: metrics) }
    private var glyphSize: CGFloat { IndicatorCardSize.glyphSize(forCardWidth: width) }

    var body: some View {
        art
            .frame(width: width, height: height)
            .saturation(desaturates ? 0 : 1)
            .overlay { if dims { Color.black.opacity(0.45) } }
            // The SAME gradient Continue Watching cards put under their chrome,
            // flipped to the top edge because the mark lives in the top-right.
            // Reusing the shared token means the mark sits on artwork the way
            // every other piece of card chrome already does.
            .overlay { if glyph != nil { MediaArtworkChromeScrim(top: true, bottom: false) } }
            .overlay(alignment: alignment) { badge }
            .overlay(alignment: .topLeading) { topLeadingPill }
            .overlay(alignment: .bottom) { bottomPill }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { dashedBorder }
            .plozzMediaEdge(cornerRadius: radius)
    }

    @ViewBuilder
    private var art: some View {
        if let url = artwork.urls[sample.id] {
            FallbackAsyncImage(urls: [url], variant: .posterCard) { syntheticArt }
        } else {
            syntheticArt
        }
    }

    /// Drawn when no poster resolves. Deliberately harsher than a flat gradient —
    /// a bright band across the top third of the pale sample and a near-black one
    /// on the dark sample — so a candidate is never flattered by an easy backdrop.
    private var syntheticArt: some View {
        LinearGradient(
            colors: [sample.fallbackTop, sample.fallbackBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var desaturates: Bool {
        treatment == .desaturated || treatment == .desaturatedAndDimmed
    }

    private var dims: Bool {
        treatment == .dimmed || treatment == .desaturatedAndDimmed
    }

    @ViewBuilder
    private var badge: some View {
        if let glyph {
            IndicatorGlyphBadge(symbol: glyph, size: glyphSize, discOpacity: discOpacity)
                .padding(badgeInset)
        }
    }

    @ViewBuilder
    private var dashedBorder: some View {
        if treatment == .dashedBorder || treatment == .dashedBorderPlusPill {
            let scale = width / PlozzTheme.Metrics.posterWidth
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .inset(by: 3 * scale)
                .strokeBorder(
                    .white.opacity(0.85),
                    style: StrokeStyle(lineWidth: 4 * scale, dash: [14 * scale, 10 * scale])
                )
                .shadow(color: .black.opacity(0.6), radius: 3)
        }
    }

    @ViewBuilder
    private var topLeadingPill: some View {
        if treatment == .textPillTopLeading || treatment == .dashedBorderPlusPill {
            notInLibraryPill.padding(badgeInset)
        }
    }

    @ViewBuilder
    private var bottomPill: some View {
        if treatment == .textPillBottom {
            notInLibraryPill.padding(.bottom, badgeInset * 2)
        }
    }

    /// Matches the existing `statusCue` pill on `PosterCardView` (white on black
    /// 72%), so this previews a treatment we already ship rather than a new
    /// invention — but scaled to the card, because the shipped pill is sized for a
    /// full poster and would run off the edge of a 167pt player card. That is
    /// itself part of the answer: text costs width that the small card doesn't
    /// have.
    private var notInLibraryPill: some View {
        let scale = width / PlozzTheme.Metrics.posterWidth
        return Text(verbatim: "Not in library")
            .font(.system(size: metrics.cardStatusCueFontSize * scale, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, metrics.cardStatusCueHorizontalPadding * scale)
            .padding(.vertical, metrics.cardStatusCueVerticalPadding * scale)
            .background(.black.opacity(0.72), in: Capsule(style: .continuous))
    }
}

// MARK: - Small building blocks

/// A focusable wrapper so tvOS can scroll a horizontal rail to this item. The
/// lift is deliberately tiny: focus must be findable without changing how the
/// candidate itself reads.
private struct GalleryFocusTile<Content: View>: View {
    @ViewBuilder let content: Content
    @FocusState private var isFocused: Bool

    var body: some View {
        content
            .focusable(true)
            .focused($isFocused)
            .scaleEffect(isFocused ? 1.04 : 1)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .inset(by: -12)
                        .strokeBorder(ThemePalette.brandBlue, lineWidth: 4)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Caption under every swatch: the symbol name (the thing to write down) plus the
/// developer note explaining why it's a candidate.
private struct GalleryCaption: View {
    let title: String  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
    var note: String?
    var width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let note {
                Text(verbatim: note)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct GallerySection<Content: View>: View {
    let marker: String
    let title: String  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
    let subtitle: String  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "\(marker). \(title)")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                Text(verbatim: subtitle)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The three backgrounds a glyph must survive, shown side by side: a near-white
/// poster corner, a mid grey, and a near-black — each under the SAME top scrim
/// the real card draws. That is the point of the strip: the scrim is what makes a
/// bare white glyph viable on pale artwork, so it has to be here or the test is
/// dishonest.
///
/// Patches are square and sized to the person-page card's width, so the glyph
/// inside them is the same optical size it is on that card.
private struct GlyphContrastStrip: View {
    let symbol: String

    @Environment(\.plozzMetrics) private var metrics

    private static let backgrounds: [Color] = [
        Color(white: 0.94),
        Color(white: 0.50),
        Color(white: 0.06)
    ]

    var body: some View {
        let patch = metrics.posterWidth * 0.36
        HStack(spacing: 10) {
            ForEach(Array(Self.backgrounds.enumerated()), id: \.offset) { _, background in
                Rectangle()
                    .fill(background)
                    .frame(width: patch, height: patch)
                    // Scaled so the ramp lands over the glyph the way it does on
                    // a full-height poster, where 34% of 420pt is a deep bed.
                    .overlay { MediaArtworkChromeScrim(top: true, bottom: false) }
                    .overlay(alignment: .topTrailing) {
                        IndicatorGlyphBadge(
                            symbol: symbol,
                            size: IndicatorCardSize.glyphSize(forCardWidth: metrics.posterWidth)
                        )
                        .padding(metrics.posterWidth * 0.035)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

// MARK: - The screen

/// Debug-only side-by-side comparison of every candidate mark for "not in your
/// library" and "you can request this". See the file header for why it exists.
public struct LibraryIndicatorGalleryView: View {
    @State private var artwork = IndicatorArtworkStore()
    @Environment(\.plozzMetrics) private var metrics

    public init() {}

    private static let glyphCardWidth: CGFloat = 320

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 64) {
                header
                chosenPair
                requestOpacityLadder
                notInLibraryShapes
                notInLibraryOnPosters
                nonGlyphTreatments
                requestShapes
                requestOnPosters
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
        .environment(artwork)
        .task { await artwork.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Library & Request indicators — design preview")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
            Text(verbatim: """
                Debug build only. Nothing here is wired into real posters yet.
                Bare white glyph over the same top scrim Continue Watching cards use — no chip, no ring. \
                Every card is a REAL size: the person page's poster (left pair, density-scaled) and the \
                in-player cast credits poster (right pair, 167×250 fixed). Stand where you normally sit.
                """)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 0 — the chosen pair

    /// What was actually picked, at the top, at both real sizes, so the decision
    /// can be sanity-checked in one glance instead of scrolling back through the
    /// candidates it beat.
    private var chosenPair: some View {
        GallerySection(
            marker: "0",
            title: "Chosen",
            subtitle: "binoculars.fill for \"not in your library\"; plus.circle.fill for \"you can request this\" (Seerr connected only). Both at the person-page size and the in-player cast size, over both posters."
        ) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 44) {
                    GalleryFocusTile {
                        chosenTile(
                            symbol: ChosenIndicator.notInLibrary,
                            discOpacity: nil,
                            caption: "not in your library",
                            note: "hierarchical — the lenses reading darker than the body is the shape"
                        )
                    }
                    GalleryFocusTile {
                        chosenTile(
                            symbol: ChosenIndicator.request,
                            discOpacity: ChosenIndicator.requestDiscOpacity,
                            caption: "you can request this",
                            note: "hierarchical, disc turned up to \(Int(ChosenIndicator.requestDiscOpacity * 100))% — see the ladder below"
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollClipDisabled()
        }
    }

    private func chosenTile(
        symbol: String,
        discOpacity: Double?,
        caption: String,  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(IndicatorCardSize.allCases) { size in
                    VStack(alignment: .leading, spacing: 12) {
                        IndicatorPosterTile(
                            sample: .pale,
                            glyph: symbol,
                            size: size,
                            discOpacity: discOpacity
                        )
                        IndicatorPosterTile(
                            sample: .dark,
                            glyph: symbol,
                            size: size,
                            discOpacity: discOpacity
                        )
                        cardSizeCaption(size)
                    }
                }
            }
            GalleryCaption(title: caption, note: "\(symbol) — \(note)", width: railTileWidth)
        }
    }

    // MARK: 0b — how solid the request disc should be

    /// Hierarchical throughout — only the disc's alpha changes. Left is closest
    /// to what hierarchical picks on its own (about half, the see-through one);
    /// right is a fully solid disc. The white is identical in every step, so none
    /// of them is brighter than another.
    private static let requestOpacitySteps: [Double] = [0.65, 0.75, 0.85, 0.95, 1.0]

    private var requestOpacityLadder: some View {
        GallerySection(
            marker: "0b",
            title: "How solid should the request disc be?",
            subtitle: "Still hierarchical — the plus stays stronger than the disc. Only the disc's alpha moves, and the white is identical in every step, so none is brighter, just less see-through. The last tile is plain hierarchical for reference."
        ) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 44) {
                    ForEach(Self.requestOpacitySteps, id: \.self) { step in
                        GalleryFocusTile {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .top, spacing: 20) {
                                    ForEach(IndicatorCardSize.allCases) { size in
                                        VStack(alignment: .leading, spacing: 12) {
                                            IndicatorPosterTile(
                                                sample: .pale,
                                                glyph: ChosenIndicator.request,
                                                size: size,
                                                discOpacity: step
                                            )
                                            IndicatorPosterTile(
                                                sample: .dark,
                                                glyph: ChosenIndicator.request,
                                                size: size,
                                                discOpacity: step
                                            )
                                        }
                                    }
                                }
                                GalleryCaption(
                                    title: "disc \(Int(step * 100))%",
                                    note: step == ChosenIndicator.requestDiscOpacity ? "current" : nil,
                                    width: railTileWidth
                                )
                            }
                        }
                    }
                    GalleryFocusTile {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 20) {
                                ForEach(IndicatorCardSize.allCases) { size in
                                    VStack(alignment: .leading, spacing: 12) {
                                        IndicatorPosterTile(
                                            sample: .pale,
                                            glyph: ChosenIndicator.request,
                                            size: size
                                        )
                                        IndicatorPosterTile(
                                            sample: .dark,
                                            glyph: ChosenIndicator.request,
                                            size: size
                                        )
                                    }
                                }
                            }
                            GalleryCaption(
                                title: "plain hierarchical",
                                note: "the see-through one — what it looked like before",
                                width: railTileWidth
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: 1 — not-in-library glyph shapes

    private var notInLibraryShapes: some View {
        GallerySection(
            marker: "1",
            title: "\"Not in your library\" — shapes",
            subtitle: "Each candidate on near-white, mid grey and near-black, under the same scrim the real card draws. If it fails here it fails everywhere."
        ) {
            glyphGrid(IndicatorGalleryCandidates.notInLibrary)
        }
    }

    // MARK: 2 — not-in-library on posters

    private var notInLibraryOnPosters: some View {
        GallerySection(
            marker: "2",
            title: "\"Not in your library\" — on posters",
            subtitle: "Top-right corner. Each candidate is shown four ways: person-page card (left column) and in-player cast card (right column), each over a pale poster and a dark one. Scroll right."
        ) {
            posterRail(IndicatorGalleryCandidates.notInLibrary)
        }
    }

    // MARK: 3 — non-glyph treatments

    private var nonGlyphTreatments: some View {
        GallerySection(
            marker: "3",
            title: "\"Not in your library\" — without an icon",
            subtitle: "Whole-poster treatments, on equal footing with the glyphs. A dashed edge or a drained poster may say \"not held\" better than any symbol, and it reads from further away."
        ) {
            ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 44) {
                    ForEach(IndicatorPosterTreatment.allCases) { treatment in
                        GalleryFocusTile {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .top, spacing: 20) {
                                    ForEach(IndicatorCardSize.allCases) { size in
                                        VStack(alignment: .leading, spacing: 12) {
                                            IndicatorPosterTile(sample: .pale, size: size, treatment: treatment)
                                            IndicatorPosterTile(sample: .dark, size: size, treatment: treatment)
                                            cardSizeCaption(size)
                                        }
                                    }
                                }
                                GalleryCaption(
                                    title: treatment.label,
                                    note: treatment.note,
                                    width: railTileWidth
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: 4 / 5 — request

    private var requestShapes: some View {
        GallerySection(
            marker: "4",
            title: "\"You can request this\" — shapes",
            subtitle: "Only ever shown when Seerr is connected. Same bare treatment, so the two marks are compared on equal terms."
        ) {
            glyphGrid(IndicatorGalleryCandidates.request)
        }
    }

    private var requestOnPosters: some View {
        GallerySection(
            marker: "5",
            title: "\"You can request this\" — on posters",
            subtitle: "Same corner, same scrim, both card sizes."
        ) {
            posterRail(IndicatorGalleryCandidates.request)
        }
    }

    // MARK: Shared layout

    private func glyphGrid(_ candidates: [IndicatorGlyphCandidate]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.glyphCardWidth), spacing: 28, alignment: .topLeading)],
            alignment: .leading,
            spacing: 28
        ) {
            ForEach(candidates) { candidate in
                GalleryFocusTile {
                    VStack(alignment: .leading, spacing: 10) {
                        GlyphContrastStrip(symbol: candidate.symbol)
                        GalleryCaption(
                            title: candidate.symbol,
                            note: candidate.note,
                            width: Self.glyphCardWidth
                        )
                    }
                }
            }
        }
    }

    /// Both real card sizes, side by side, each over both posters — so a
    /// candidate is judged where it will actually appear rather than at one
    /// convenient size. The person-page card is density-scaled; the player's cast
    /// card is a fixed 167×250 and is the harder test by a wide margin.
    private func posterRail(_ candidates: [IndicatorGlyphCandidate]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 44) {
                ForEach(candidates) { candidate in
                    GalleryFocusTile {
                        candidateTile(candidate)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .scrollClipDisabled()
    }

    private func candidateTile(_ candidate: IndicatorGlyphCandidate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(IndicatorCardSize.allCases) { size in
                    VStack(alignment: .leading, spacing: 12) {
                        IndicatorPosterTile(sample: .pale, glyph: candidate.symbol, size: size)
                        IndicatorPosterTile(sample: .dark, glyph: candidate.symbol, size: size)
                        cardSizeCaption(size)
                    }
                }
            }
            GalleryCaption(
                title: candidate.symbol,
                note: candidate.note,
                width: railTileWidth
            )
        }
    }

    /// Names the card and states its measured geometry, so the screen answers
    /// "how big is this actually?" without anyone reading the source.
    private func cardSizeCaption(_ size: IndicatorCardSize) -> some View {
        let w = size.width(metrics: metrics)
        let h = size.height(metrics: metrics)
        let glyph = IndicatorCardSize.glyphSize(forCardWidth: w)
        return Text(verbatim: "\(size.label) · \(Int(w))×\(Int(h)) · glyph \(Int(glyph))pt")
            .font(.system(size: 15, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
            .frame(width: w, alignment: .leading)
    }

    /// Width of one candidate's whole block: both cards plus the gap between
    /// them, so the caption underneath wraps to the tile rather than the screen.
    private var railTileWidth: CGFloat {
        IndicatorCardSize.personPage.width(metrics: metrics)
            + IndicatorCardSize.playerCast.width(metrics: metrics)
            + 20
    }
}
#endif
