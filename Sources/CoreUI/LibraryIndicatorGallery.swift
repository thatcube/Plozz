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

// MARK: - Chip treatments

/// How a glyph is painted onto artwork. The real question behind the icon choice
/// is not only *which* glyph but *what carries it* — a bare white glyph dies on a
/// pale poster, and a brand-blue chip is already spoken for by "watched".
enum IndicatorChipTreatment: String, CaseIterable, Identifiable {
    /// Glyph alone, white, with a drop shadow. Cheapest, most fragile.
    case bare
    /// White glyph on a black 55% circle. The safest thing that works on anything.
    case darkChip
    /// White glyph on a frosted circle, falling back to a solid fill under
    /// Reduce Transparency (which the app must honour).
    case frostedChip
    /// Apple's own treatment for the "external" badge: a neutral grey FILLED
    /// glyph with no chip at all. This is the one Brandon described.
    case neutralGrey
    /// The brand-blue chip the watched badge uses — included so it is obvious
    /// that reusing it would collide with "watched".
    case brandChip

    var id: String { rawValue }

    var label: String {  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
        switch self {
        case .bare: return "bare glyph + shadow"
        case .darkChip: return "white on black 55% circle"
        case .frostedChip: return "white on frosted circle"
        case .neutralGrey: return "neutral grey fill, no chip"
        case .brandChip: return "brand blue chip (= watched)"
        }
    }
}

/// A single candidate glyph painted in one treatment at production size.
struct IndicatorGlyphBadge: View {
    let symbol: String
    var treatment: IndicatorChipTreatment = .darkChip
    /// Diameter of the chip. Defaults to the watched badge's production size so
    /// anything judged here is judged at the size it would actually ship at.
    var size: CGFloat = PlozzTheme.Metrics.watchedBadgeSize

    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    var body: some View {
        if IndicatorSymbolAvailability.exists(symbol) {
            content
        } else {
            // A missing symbol renders as nothing, which would silently look like
            // "this candidate is invisible". Say so instead.
            Text(verbatim: "!")
                .font(.system(size: size * 0.6, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.red))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch treatment {
        case .bare:
            glyph(size: size * 0.86, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.65), radius: size * 0.12, y: size * 0.03)
        case .darkChip:
            glyph(size: size * 0.52, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay {
                    Circle()
                        .inset(by: -0.5)
                        .stroke(.white.opacity(0.35), lineWidth: max(1.5, size * 0.04))
                }
                .shadow(color: .black.opacity(0.4), radius: size * 0.08, y: size * 0.026)
        case .frostedChip:
            glyph(size: size * 0.52, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background {
                    // Reduce Transparency must reach every translucent surface, so
                    // the blur has a solid stand-in rather than simply vanishing.
                    if reduceTransparency {
                        Circle().fill(Color(white: 0.18))
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay {
                    Circle()
                        .inset(by: -0.5)
                        .stroke(.white.opacity(0.35), lineWidth: max(1.5, size * 0.04))
                }
                .shadow(color: .black.opacity(0.4), radius: size * 0.08, y: size * 0.026)
        case .neutralGrey:
            glyph(size: size * 0.86, weight: .semibold)
                .foregroundStyle(Color(white: 0.72))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.5), radius: size * 0.1, y: size * 0.03)
        case .brandChip:
            glyph(size: size * 0.52, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(ThemePalette.brandBlue))
                .overlay {
                    Circle()
                        .inset(by: -0.5)
                        .stroke(.white.opacity(0.4), lineWidth: max(1.5, size * 0.04))
                }
                .shadow(color: .black.opacity(0.4), radius: size * 0.08, y: size * 0.026)
        }
    }

    private func glyph(size: CGFloat, weight: Font.Weight) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(.hierarchical)
    }
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

// MARK: - Poster tile

/// A poster at the production footprint (280×420, the real corner radius and rim)
/// carrying one candidate treatment. Everything on this screen is judged on one
/// of these, because a glyph in a vacuum tells you nothing about whether it
/// survives artwork.
struct IndicatorPosterTile: View {
    let sample: IndicatorArtworkSample
    var glyph: String?
    var chip: IndicatorChipTreatment = .darkChip
    /// Always the top-right — the watch-status slot, which is free for an unowned
    /// title because watch state cannot apply to something you don't have.
    private let alignment: Alignment = .topTrailing
    var treatment: IndicatorPosterTreatment = .none

    @Environment(\.plozzMetrics) private var metrics
    @Environment(IndicatorArtworkStore.self) private var artwork

    private let width: CGFloat = PlozzTheme.Metrics.posterWidth
    private var height: CGFloat { width * 1.5 }
    private var radius: CGFloat { PlozzTheme.Metrics.posterArtCornerRadius }
    private var badgeInset: CGFloat { 8 }

    var body: some View {
        art
            .frame(width: width, height: height)
            .saturation(desaturates ? 0 : 1)
            .overlay { if dims { Color.black.opacity(0.45) } }
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
            IndicatorGlyphBadge(symbol: glyph, treatment: chip, size: metrics.watchedBadgeSize)
                .padding(badgeInset)
        }
    }

    @ViewBuilder
    private var dashedBorder: some View {
        if treatment == .dashedBorder || treatment == .dashedBorderPlusPill {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .inset(by: 3)
                .strokeBorder(
                    .white.opacity(0.85),
                    style: StrokeStyle(lineWidth: 4, dash: [14, 10])
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
            notInLibraryPill.padding(.bottom, 16)
        }
    }

    /// Matches the existing `statusCue` pill on `PosterCardView` exactly (white on
    /// black 72%), so this is a real preview of the treatment we already ship
    /// rather than a new invention.
    private var notInLibraryPill: some View {
        Text(verbatim: "Not in library")
            .font(.system(size: metrics.cardStatusCueFontSize, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, metrics.cardStatusCueHorizontalPadding)
            .padding(.vertical, metrics.cardStatusCueVerticalPadding)
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
    let number: Int
    let title: String  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
    let subtitle: String  // l10n:content — DEBUG-only design-preview label; never shipped, never translated
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "\(number). \(title)")
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
/// poster corner, a mid grey, and a near-black. This is the fastest way to catch
/// a candidate that only works over dark artwork.
private struct GlyphContrastStrip: View {
    let symbol: String
    var treatment: IndicatorChipTreatment = .darkChip

    private let patch: CGFloat = 92
    private static let backgrounds: [Color] = [
        Color(white: 0.94),
        Color(white: 0.50),
        Color(white: 0.06)
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(Self.backgrounds.enumerated()), id: \.offset) { _, background in
                Rectangle()
                    .fill(background)
                    .frame(width: patch, height: patch)
                    .overlay(alignment: .topTrailing) {
                        IndicatorGlyphBadge(symbol: symbol, treatment: treatment)
                            .padding(8)
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

    public init() {}

    private static let glyphCardWidth: CGFloat = 320

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 64) {
                header
                notInLibraryShapes
                notInLibraryOnPosters
                nonGlyphTreatments
                requestShapes
                requestOnPosters
                treatmentStudy
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
                Every glyph is drawn at the production watched-badge size (\(Int(PlozzTheme.Metrics.watchedBadgeSize))pt) in the \
                real corner slot on a real 280×420 poster, over pale and dark artwork. Stand where you normally sit.
                """)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 1 — not-in-library glyph shapes

    private var notInLibraryShapes: some View {
        GallerySection(
            number: 1,
            title: "\"Not in your library\" — shapes",
            subtitle: "Each candidate on near-white, mid grey and near-black, in the safest treatment (white on a dark chip). If it fails here it fails everywhere."
        ) {
            glyphGrid(IndicatorGalleryCandidates.notInLibrary)
        }
    }

    // MARK: 2 — not-in-library on posters

    private var notInLibraryOnPosters: some View {
        GallerySection(
            number: 2,
            title: "\"Not in your library\" — on posters",
            subtitle: "Top-right corner, over a pale poster (top) and a dark poster (bottom). Scroll right through the candidates."
        ) {
            posterRail(IndicatorGalleryCandidates.notInLibrary, chip: .darkChip)
        }
    }

    // MARK: 3 — non-glyph treatments

    private var nonGlyphTreatments: some View {
        GallerySection(
            number: 3,
            title: "\"Not in your library\" — without an icon",
            subtitle: "Whole-poster treatments, on equal footing with the glyphs. A dashed edge or a drained poster may say \"not held\" better than any symbol, and it reads from further away."
        ) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 32) {
                    ForEach(IndicatorPosterTreatment.allCases) { treatment in
                        GalleryFocusTile {
                            VStack(alignment: .leading, spacing: 14) {
                                IndicatorPosterTile(sample: .pale, treatment: treatment)
                                IndicatorPosterTile(sample: .dark, treatment: treatment)
                                GalleryCaption(
                                    title: treatment.label,
                                    note: treatment.note,
                                    width: PlozzTheme.Metrics.posterWidth
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
            number: 4,
            title: "\"You can request this\" — shapes",
            subtitle: "Only ever shown when Seerr is connected. This one is an ACTION, so it may earn colour where the not-in-library mark should not."
        ) {
            glyphGrid(IndicatorGalleryCandidates.request)
        }
    }

    private var requestOnPosters: some View {
        GallerySection(
            number: 5,
            title: "\"You can request this\" — on posters",
            subtitle: "Same corner, brand-blue chip — the treatment an actionable mark would plausibly get."
        ) {
            posterRail(IndicatorGalleryCandidates.request, chip: .brandChip)
        }
    }

    // MARK: 6 — treatment study

    private var treatmentStudy: some View {
        GallerySection(
            number: 6,
            title: "What carries the glyph",
            subtitle: "One shape (cloud.fill), five treatments, over both posters. The chip matters at least as much as the symbol: a bare white glyph dies on pale artwork, and the brand-blue chip is already spoken for by \"watched\"."
        ) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 32) {
                    ForEach(IndicatorChipTreatment.allCases) { treatment in
                        GalleryFocusTile {
                            VStack(alignment: .leading, spacing: 14) {
                                IndicatorPosterTile(sample: .pale, glyph: "cloud.fill", chip: treatment)
                                IndicatorPosterTile(sample: .dark, glyph: "cloud.fill", chip: treatment)
                                GalleryCaption(
                                    title: treatment.label,
                                    note: nil,
                                    width: PlozzTheme.Metrics.posterWidth
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

    private func posterRail(
        _ candidates: [IndicatorGlyphCandidate],
        chip: IndicatorChipTreatment
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 32) {
                ForEach(candidates) { candidate in
                    GalleryFocusTile {
                        VStack(alignment: .leading, spacing: 14) {
                            IndicatorPosterTile(sample: .pale, glyph: candidate.symbol, chip: chip)
                            IndicatorPosterTile(sample: .dark, glyph: candidate.symbol, chip: chip)
                            GalleryCaption(
                                title: candidate.symbol,
                                note: candidate.note,
                                width: PlozzTheme.Metrics.posterWidth
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
#endif
