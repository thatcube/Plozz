#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit


/// A person's page: who they are, and what else the viewer owns with them.
///
/// In FeatureHomeCore rather than FeatureHome, alongside the view model it
/// drives. The view was already written to build for iOS — its one piece of
/// tvOS-only API is guarded at the foot of this file — but FeatureHome carries
/// unguarded tvOS API elsewhere and so is never compiled for iOS, which stranded
/// it. The in-player cast card needs somewhere to send "See more" on both
/// platforms.
///
/// The header is free — name, character and headshot all arrive with the item
/// the person was listed on — so the page is never empty even when the source
/// cannot answer for credits.
public struct PersonDetailView: View {
    private let person: MediaPerson
    /// `@State`, not `let`: a `navigationDestination` closure re-runs on every
    /// render pass while its page is on the stack, so a plain stored property
    /// would be replaced by a freshly-built model — reset to `.loading` — on each
    /// one, while `.task` (keyed to the unchanged view identity) never ran again.
    /// The spinner then never resolved. `ItemDetailView` keeps its model the same
    /// way, and for the same reason.
    @State private var viewModel: PersonDetailViewModel
    private let onSelectItem: (MediaItem) -> Void

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.dismiss) private var dismiss

    /// Until credits arrive there is nothing focusable on this page, and on tvOS a
    /// screen with no focusable element makes Menu quit the app rather than pop —
    /// the same hazard the empty/loading folder states guard against. So every
    /// creditless state carries a focused Back button.
    @FocusState private var backFocused: Bool

    /// The page's own width, so the two measures below can answer to it.
    @State private var availableWidth: CGFloat = 0

    /// Across a room this is 220; on a phone that is most of the screen.
    ///
    /// A share of the width with a ceiling rather than a breakpoint: this page is
    /// now shown on everything from a 320pt phone to a television, and a value
    /// that is right at two sizes and wrong between them is not responsive.
    private var headshotDiameter: CGFloat {
        guard availableWidth > 0 else { return 220 }
        return min(220, (availableWidth * 0.3).rounded())
    }

    /// Reading measure for the biography — roughly 90 characters at tvOS's size,
    /// and never wider than the page, which 1000 is on every phone.
    private var biographyWidth: CGFloat {
        guard availableWidth > 0 else { return 1000 }
        return min(1000, availableWidth)
    }

    /// Display name for each library id the viewer has, so owned credits can be
    /// shelved under the libraries they actually came from.
    ///
    /// Keyed by the provider-local library id that `MediaItem.libraryID` carries.
    /// Empty is a supported state — a viewer whose libraries have not been
    /// discovered yet falls back to shelving by kind.
    private let libraryNames: [String: String]

    public init(
        person: MediaPerson,
        viewModel: PersonDetailViewModel,
        libraryNames: [String: String] = [:],
        onSelectItem: @escaping (MediaItem) -> Void
    ) {
        self.person = person
        _viewModel = State(initialValue: viewModel)
        self.libraryNames = libraryNames
        self.onSelectItem = onSelectItem
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PlozzTheme.Spacing.large) {
                header
                credits
            }
            .padding(.top, PlozzTheme.Spacing.large)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in
                        availableWidth = width
                    }
            }
        }
        .task { await viewModel.load() }
    }

    /// Headshot on the left, name and biography beside it, the pair centred on
    /// screen.
    ///
    /// No character name. This page is about the person, not the one title the
    /// viewer happened to arrive from — "Bilbo Baggins" is a fact about The
    /// Hobbit, and it reads as a subtitle on a page that then lists a dozen
    /// other roles.
    private var header: some View {
        HStack(alignment: .center, spacing: PlozzTheme.Spacing.large) {
            headshot
            VStack(alignment: .leading, spacing: PlozzTheme.Spacing.small) {
                Text(person.name)
                    .font(.system(size: metrics.sectionHeaderFontSize * 1.6, weight: .bold))
                if let kind = person.kind, !kind.isEmpty, !person.isCast {
                    // Crew keep their discipline (Director, Writer): unlike a
                    // character it describes the person, not one credit.
                    Text(kind)
                        .font(.system(size: metrics.sectionHeaderFontSize * 0.8))
                        .plozzForeground(.secondary)
                }
                if let biography = viewModel.biography {
                    ExpandableOverviewText(
                        text: biography,
                        title: person.name,
                        lineLimit: 3,
                        font: .system(size: metrics.sectionHeaderFontSize * 0.72)
                    )
                    .plozzForeground(.secondary)
                    .padding(.top, PlozzTheme.Spacing.small)
                }
            }
            // Held well short of the screen: a full-width line of body text is
            // far past a comfortable reading measure at this size, and from
            // across a room it becomes hard to track from the end of one line to
            // the start of the next.
            .frame(maxWidth: biographyWidth, alignment: .leading)
        }
        // The pair sits centred, rather than pinned to the leading edge.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        // A full-width focus section, because the only focusable thing up here
        // is the biography — and it sits to the RIGHT of the headshot. Without
        // this, pressing Up from the left-most credit finds nothing above it
        // (the headshot is not focusable) and the press dies. A section captures
        // the movement across the whole width and redirects it inward, so Up
        // reaches the biography from anywhere along the row. Same fix, and the
        // same reason, as the player's bottom tab row.
        .personFocusSection()
    }

    @ViewBuilder
    private var headshot: some View {
        Group {
            if let url = person.imageURL {
                FallbackAsyncImage(urls: [url], variant: .personHeadshot) { headshotPlaceholder }
            } else {
                headshotPlaceholder
            }
        }
        .frame(width: headshotDiameter, height: headshotDiameter)
        .clipShape(Circle())
    }

    /// Initials on a tinted disc — the same fallback the cast rail uses, so a
    /// person with no headshot reads as "no photo" rather than a broken image.
    private var headshotPlaceholder: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.12))
            Text(initials)
                .font(.system(size: headshotDiameter * 0.28, weight: .semibold))
                .plozzForeground(.secondary)
        }
    }

    private var initials: String {
        let parts = person.name.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }

    @ViewBuilder
    private var credits: some View {
        switch viewModel.state {
        // Waits for the ORDER to settle, not merely for credits to exist.
        //
        // The viewer's own server answers in tens of milliseconds and the
        // outside rungs take up to a few seconds, and the last thing they do is
        // re-sort everything by how prominent the person was — so rendering on
        // arrival puts the page up in library order and visibly reshuffles it
        // underneath whoever is already reading it. The header, headshot and
        // biography are unaffected and still appear immediately, so the page is
        // never blank while this waits.
        case .loaded where !viewModel.libraryCredits.isEmpty && viewModel.creditsAreFinal:
            // Rows are focusable, so this is the one state that needs no Back
            // button of its own.
            VStack(alignment: .leading, spacing: 0) {
                // What they are known for, in the order the ranking produced.
                //
                // First and unsegmented, because splitting by kind is what
                // destroys that ranking: the whole point is that Sherlock
                // outranks a film, and a Movies shelf above a TV Shows shelf
                // cannot say so. It also answers for a voice actor whose entire
                // body of work is animation without the app having to decide
                // what counts as anime.
                shelf(
                    LocalizedStringResource(
                        "Known for",
                        comment: "Heading for a shelf of the titles a person is best known for, shown at the top of their page. Includes titles the viewer does not own."
                    ),
                    items: viewModel.libraryCredits
                )

                // Then what the viewer actually owns, shelved by the library it
                // came from.
                ForEach(ownedShelves, id: \.key) { group in
                    shelfBody(group.title.text, items: group.items)
                }
            }
        case .loading, .loaded where !viewModel.creditsAreFinal:
            // No Back button here, unlike the creditless state below.
            //
            // A full-width button under two placeholder shelves is a lot of
            // furniture for a state that lasts a second, and it is not what the
            // eye should land on. The page still has a way out: Menu pops the
            // navigation stack whether or not anything here holds focus, and the
            // shelves that replace this are focusable the moment they arrive.
            creditShelfSkeleton
        case .loaded, .unavailable:
            // A source that couldn't answer and a person with genuinely nothing
            // else are indistinguishable here, and either way the honest thing to
            // say is that there is nothing to show.
            creditlessState {
                Text(
                    "Nothing else in your library with \(person.name).",
                    comment: "Empty state on a person's page. The placeholder is a person's name. Means the viewer owns nothing else featuring them, not that a lookup failed."
                )
                    .font(.system(size: metrics.sectionHeaderFontSize))
                    .multilineTextAlignment(.center)
                    .plozzForeground(.secondary)
            }
        }
    }

    /// One shelf of the person's work, or nothing when they have none of that
    /// kind. Split by kind because a prolific actor's single mixed row buries
    /// films among a dozen series (and vice versa), and the two are usually
    /// looked for separately.
    ///
    /// `kinds: nil` means "everything not claimed by a named row above", so no
    /// item can be silently dropped by adding a row.
    @ViewBuilder
    /// Stand-in shelves while the credit order is being settled.
    ///
    /// The same shape the real shelves take, so filling them in shifts nothing —
    /// a spinner sat in the middle of the page and then the whole thing jumped
    /// as rows appeared around it. Two rows because that is the common outcome:
    /// what they are known for, and what of it the viewer owns.
    ///
    /// Not focusable, so the engine can never anchor on a placeholder and strand
    /// focus where a real card is about to be. Back stays reachable because the
    /// header above it is focusable in its own right.
    private var creditShelfSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
                    // A bar where the heading will be, rather than a guess at
                    // its wording: naming a shelf that may not arrive is worse
                    // than not naming it.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.10))
                        .frame(width: 240, height: metrics.sectionHeaderFontSize)
                        .padding(.leading, PlozzTheme.Metrics.screenPadding)
                    // The same nested horizontal viewport the real rows use. A
                    // plain HStack reports its full intrinsic width to the outer
                    // vertical ScrollView even when clipped, which widens the
                    // page and lets tvOS pan it sideways while the skeleton is
                    // up — the exact problem documented on the Related row.
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: metrics.cardSpacing) {
                            ForEach(0..<Self.skeletonCardCount, id: \.self) { _ in
                                SkeletonCardView(style: .poster)
                                    .frame(width: metrics.posterWidth)
                            }
                        }
                        .padding(.leading, PlozzTheme.Metrics.screenPadding)
                        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                        .padding(.vertical, metrics.railShadowClearance)
                    }
                    .padding(.top, metrics.railTopClearanceOffset)
                    .padding(.bottom, metrics.railBottomClearanceOffset)
                    .scrollDisabled(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Enough to read as a row without measuring the viewport — clipped at the
    /// trailing edge exactly as real cards are.
    private static let skeletonCardCount = 8

    private func shelf(_ title: LocalizedStringResource, items: [MediaItem]) -> some View {
        shelfBody(Text(title), items: items)
    }

    @ViewBuilder
    private func shelfBody(_ title: Text, items: [MediaItem]) -> some View {
        if !items.isEmpty {
            MediaRowView(title: title, items: items, onSelect: onSelectItem)
                // Each shelf is its own focus section, which MediaRowView
                // deliberately does NOT do by default — ordinary rows stay
                // unsectioned to preserve tvOS's column-aligned projection.
                //
                // This page has to override that, because its header cannot
                // satisfy the projection: the biography is the only focusable
                // thing up there and it sits to the RIGHT of the headshot, so
                // nothing focusable is ever above a left-most card. With a
                // single movie at the left edge, Down from the biography found
                // no candidate in its corridor and skipped the whole Movies row
                // to land in TV Shows. A section captures the movement across
                // the full width instead, and remembers the last card focused
                // within it, so returning to a shelf comes back where you left.
                .personFocusSection()
        }
    }

    /// The owned credits, grouped into the shelves shown beneath "Known for".
    ///
    /// Grouped by the LIBRARY each title came from rather than by its kind, so
    /// the page mirrors how the viewer actually organises their media. Someone
    /// who keeps a separate Anime library gets an Anime shelf without the app
    /// classifying anything — which matters, because per-title anime detection
    /// is a heuristic that gets Arcane, Castlevania and Blue Eye Samurai wrong
    /// in one direction or the other. Someone with a Documentaries library gets
    /// that shelf too, for free.
    ///
    /// Keyed on the library's NAME, not its id, so the same library on two
    /// servers — a very common setup — collapses into one shelf instead of two
    /// identically titled ones.
    private var ownedShelves: [(key: String, title: ShelfTitle, items: [MediaItem])] {
        let owned = viewModel.libraryCredits.filter { $0.availability != .unknown }
        guard !owned.isEmpty else { return [] }

        var groups: [String: [MediaItem]] = [:]
        var titles: [String: ShelfTitle] = [:]
        var order: [String] = []
        for item in owned {
            let title = item.libraryID.flatMap { libraryNames[$0] }
                .map(ShelfTitle.library) ?? Self.fallbackTitle(item)
            let key = title.key
            if groups[key] == nil { order.append(key); titles[key] = title }
            groups[key, default: []].append(item)
        }

        var shelves = order.map {
            (key: $0, title: titles[$0] ?? .other, items: groups[$0] ?? [])
        }
        // A page of one-title shelves is worse than a page of two useful ones.
        // Past a handful of libraries the smallest are folded together rather
        // than each taking a full row's height for a single poster.
        if shelves.count > Self.maximumOwnedShelves {
            let sorted = shelves.sorted { $0.items.count > $1.items.count }
            let kept = Array(sorted.prefix(Self.maximumOwnedShelves - 1))
            let rest = sorted.dropFirst(Self.maximumOwnedShelves - 1).flatMap(\.items)
            shelves = kept
            if !rest.isEmpty {
                shelves.append((key: ShelfTitle.other.key, title: .other, items: rest))
            }
        }
        return shelves
    }

    /// A shelf heading, which is either the server's own library name or Plozz's
    /// wording — and those are localized differently.
    ///
    /// A library's name is content: it is whatever the viewer called their
    /// library and must render verbatim. Everything else here is app copy and
    /// has to go through the catalog, which is exactly the distinction the
    /// localization guard exists to enforce.
    private enum ShelfTitle {
        case library(String)
        case movies
        case series
        case other

        var key: String {
            switch self {
            case .library(let name): return "library:\(name)"
            case .movies: return "kind:movies"
            case .series: return "kind:series"
            case .other: return "kind:other"
            }
        }

        var text: Text {
            switch self {
            case .library(let name):
                return Text(verbatim: name)
            case .movies:
                return Text("Movies")
            case .series:
                return Text("TV Shows")
            case .other:
                return Text(LocalizedStringResource(
                    "person.shelf.inYourLibrary",
                    defaultValue: "In your library",
                    comment: "Heading for a shelf of titles the viewer owns featuring this person, used when the title's library is unknown or several small libraries are folded together."
                ))
            }
        }
    }

    /// Used when a title carries no library — a share catalog answering from its
    /// own records, or libraries that have not been discovered yet.
    private static func fallbackTitle(_ item: MediaItem) -> ShelfTitle {
        switch item.kind {
        case .movie: return .movies
        case .series, .episode: return .series
        default: return .other
        }
    }

    private static let maximumOwnedShelves = 4

    /// Any state with no credits row: the given content plus the focusable Back
    /// button that keeps Menu working.
    private func creditlessState(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: PlozzTheme.Spacing.large) {
            content()
            goBackButton
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .defaultFocus($backFocused, true)
    }

    /// The page's own way out.
    ///
    /// Shared with the loading state rather than living only in `creditlessState`,
    /// because a page whose only focusable content is a placeholder has nowhere
    /// for focus to rest — and this button is what keeps Menu working while
    /// there is nothing else to hold it.
    private var goBackButton: some View {
        Button {
            dismiss()
        } label: {
            Label("Go Back", systemImage: "chevron.backward")
                .frame(minWidth: 260)
        }
        .buttonStyle(.borderedProminent)
        .focused($backFocused)
    }
}
private extension View {
    /// `focusSection()` where it exists. tvOS-only API, and this view also builds
    /// for iOS.
    @ViewBuilder
    func personFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }
}
#endif
