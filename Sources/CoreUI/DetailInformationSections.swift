#if canImport(SwiftUI)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

/// Shared title-level detail sections. Platform shells keep their own Cast rail
/// first, then place this view beneath it so content and ordering stay identical
/// while the adaptive grids naturally collapse on iPhone.
#if os(tvOS) && canImport(UIKit)
/// Makes the presenting sheet's own host transparent, so the card floats over
/// the page (dimmed) instead of on an opaque full-screen plate.
private struct ClearSheetBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#else
private struct ClearSheetBackground: View {
    var body: some View { Color.clear }
}
#endif

private struct OverviewCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

public struct DetailInformationSections: View {
    private let item: MediaItem
    private let horizontalInset: CGFloat
    private let selectedSource: MediaSourceRef?
    private let selectedVersion: MediaVersion?
    private let externalAvailability: ExternalTitleAvailability?
    /// The viewer's spoiler protection. Ratings honour it here exactly as the
    /// heroes above do — the section is blurred, not removed, so a deliberate
    /// press can still lift it.
    private let spoilerSettings: SpoilerSettings

    @State private var showsFullOverview = false
    @State private var overviewCardHeight: CGFloat = 0
    @State private var overviewFullHeight: CGFloat = 0
    @State private var overviewVisibleHeight: CGFloat = 0
    /// Height the About card would take at its *base* line cap, measured from a
    /// hidden copy. The ratings column is floored at this, so the two columns end
    /// on the same line. Measured at the base cap (never the adjusted one) so it
    /// cannot feed back into the cap that is derived from it.
    @State private var aboutBaseCardHeight: CGFloat = 0
    /// The height the ratings column actually settled on. When the tiles wrap this
    /// exceeds the About card, and About grows — and shows more text — to match.
    @State private var ratingsBlockHeight: CGFloat = 0
    /// One line of body text, so surplus height converts to a line count rather
    /// than a guess. Measured, so it tracks Dynamic Type.
    @State private var bodyLineHeight: CGFloat = 0
    @Environment(\.themePalette) private var palette

    public init(
        item: MediaItem,
        horizontalInset: CGFloat,
        selectedSource: MediaSourceRef? = nil,
        selectedVersion: MediaVersion? = nil,
        externalAvailability: ExternalTitleAvailability? = nil,
        spoilerSettings: SpoilerSettings = .default
    ) {
        self.item = item
        self.horizontalInset = horizontalInset
        self.selectedSource = selectedSource
        self.selectedVersion = selectedVersion
        self.externalAvailability = externalAvailability
        self.spoilerSettings = spoilerSettings
    }

    public var body: some View {
        if hasContent {
            sectionBody
                .padding(.horizontal, horizontalInset)
                .padding(.top, bandTopPadding)
                .padding(.bottom, bandBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A subtle full-bleed tint marks the lower "info" band as its own
                // zone. Deliberately quiet, and distinct from the cards inside it
                // (which sit on their own surface).
                //
                // "Full-bleed" has to be painted, not declared: this sits inside a
                // ScrollView, which has already consumed the container's safe area
                // and turned it into content insets, so `ignoresSafeArea` here has
                // nothing left to ignore. tvOS's overscan margin kept the tint off
                // the left and right edges, and on both platforms the strip below
                // the last content (home indicator / tab bar / bottom overscan)
                // stayed page-coloured. Negative padding on the *background* layer
                // reaches past all of it without touching the layout — a background
                // never affects the size of what it sits behind.
                .background {
                    palette.informationSurface
                        .padding(.horizontal, -Self.backgroundBleed)
                        .padding(.bottom, -Self.backgroundBleed)
                }
        }
    }

    /// Overshoot for the band's tint. Generous on purpose: it only has to exceed
    /// the largest inset it might be sitting inside (tvOS overscan, an iPhone home
    /// indicator, a tab bar), and the screen edge does the clipping. It is drawn
    /// behind the content and below the last of it, so there is nothing for the
    /// overshoot to cover up.
    private static let backgroundBleed: CGFloat = 400

    @ViewBuilder
    private var sectionBody: some View {
        #if os(tvOS)
        proportionalGrid
        #else
        if horizontalSizeClass == .regular {
            proportionalGrid
        } else {
            iPhoneStack
        }
        #endif
    }

    private var bandTopPadding: CGFloat {
        #if os(tvOS)
        44
        #else
        horizontalSizeClass == .regular ? 32 : 24
        #endif
    }

    private var bandBottomPadding: CGFloat {
        #if os(tvOS)
        60
        #else
        horizontalSizeClass == .regular ? 44 : 32
        #endif
    }

    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// iPhone (compact width): a simple vertical stack. About, Ratings and each
    /// Information group stack full-width with their own large headers.
    private var iPhoneStack: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            if hasAbout {
                detailSection(title: LocalizedStringResource(
                    "mediaDetail.section.about",
                    defaultValue: "About",
                    comment: "Header of the synopsis section on a movie or series detail page. A noun meaning 'about this title', not the Settings > About page."
                )) { aboutContent }
            }
            if !item.ratings.isEmpty {
                detailSection(title: "Ratings") { ratingsTiles }
            }
            if !informationGroups.isEmpty {
                informationGrid
            }
        }
    }
    #endif

    /// Shared proportional 12-track grid used on tvOS and regular-width iPad, so
    /// both platforms subdivide the same spine: About (⅔) sits above
    /// Details+Playback (⅔), and Ratings (⅓) sits above File (⅓) — every column
    /// edge lines up.
    private var proportionalGrid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: gridSpacing, verticalSpacing: 0) {
            // Zero-height priming row: pins twelve equal tracks so every section
            // below subdivides the same spine (About ⅔ = Details+Playback,
            // Ratings ⅓ = File).
            GridRow {
                ForEach(0..<12, id: \.self) { _ in
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 0)
                }
            }

            if hasAbout || !item.ratings.isEmpty {
                GridRow(alignment: .top) {
                    if hasAbout {
                        headedSection(title: LocalizedStringResource(
                            "mediaDetail.section.about",
                            defaultValue: "About",
                            comment: "Header of the synopsis section on a movie or series detail page. A noun meaning 'about this title', not the Settings > About page."
                        )) { aboutContent }
                            .gridCellColumns(4)
                    } else {
                        Color.clear.gridCellColumns(4)
                    }
                    if !item.ratings.isEmpty {
                        headedSection(title: "Ratings") { ratingsTiles }
                            .gridCellColumns(8)
                    } else {
                        Color.clear.gridCellColumns(8)
                    }
                }
            }

            if !informationGroups.isEmpty {
                GridRow(alignment: .top) {
                    ForEach(informationGroups) { group in
                        informationGroup(group)
                            // tvOS reserves the borderless focus plate's outward
                            // growth (cardPadding + 8pt) so a focused column's
                            // plate lands inside its own keyline. iOS has no focus
                            // plate, so the grid gutter alone spaces the columns.
                            .padding(.trailing, infoColumnFocusInset)
                            .gridCellColumns(informationColumnSpan)
                    }
                    if informationGroups.count * informationColumnSpan < 12 {
                        Color.clear
                            .gridCellColumns(12 - informationGroups.count * informationColumnSpan)
                    }
                }
                .padding(.top, sectionSpacing)
            }
        }
    }

    private var infoColumnFocusInset: CGFloat {
        #if os(tvOS)
        cardPadding + 8
        #else
        0
        #endif
    }

    private func headedSection<Content: View>(
        title: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(sectionTitleFont)
            content()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var ratingsTiles: some View {
        // One layout for both platforms and both arrangements. Each tile takes a
        // quarter of the width, so a single rating reads as one of four rather
        // than stretching across the column as if it were a table, and four fill
        // the row. When the column is too narrow for quarters the tiles wrap and
        // divide whatever is there, instead of shrinking below legibility to
        // preserve a share that no longer fits.
        //
        // Height matching is an *input* (`minimumHeight`), not something the
        // container does to us: the layout reports the About card's height as its
        // own, so the tiles reach the bottom of About without depending on a Grid
        // choosing to stretch the cell.
        SpoilerRevealBox(
            isHidden: hidesRatings,
            prompt: LocalizedStringResource(
                "mediaDetail.ratings.reveal",
                defaultValue: "Show Ratings",
                comment: "Button over the blurred Ratings section of a title's detail page; pressing it reveals scores that spoiler protection is hiding."
            ),
            identity: item.id
        ) {
            ProportionalWrapLayout(
                preferredColumns: 4,
                minimumCellWidth: ratingsTileMinWidth,
                spacing: ratingsTileSpacing,
                minimumHeight: matchesRatingsHeight ? aboutBaseCardHeight : 0
            ) {
                ForEach(sortedRatings) { rating in
                    RatingTile(rating: rating)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Report the height back so About can grow to meet it when the tiles wrap.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RatingsBlockHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .onPreferenceChange(RatingsBlockHeightKey.self) { ratingsBlockHeight = $0 }
        }
    }

    /// Whether spoiler protection currently covers this title's scores.
    ///
    /// Deliberately the same `shouldHideRatings` the detail and Home heroes ask,
    /// so one setting cannot produce two answers on a single screen: an unwatched
    /// movie whose hero badges are suppressed must not have its scores printed at
    /// display size two sections further down.
    private var hidesRatings: Bool {
        spoilerSettings.shouldHideRatings(for: item)
    }

    /// Whether About and Ratings sit side-by-side and should be the same height
    /// (tvOS and regular-width iPad). iPhone stacks them, so no matching.
    private var matchesRatingsHeight: Bool {
        guard hasAbout, !item.ratings.isEmpty else { return false }
        #if os(tvOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    private var ratingsTileMinWidth: CGFloat {
        #if os(tvOS)
        210
        #else
        horizontalSizeClass == .compact ? 130 : 150
        #endif
    }

    private var ratingsTileSpacing: CGFloat {
        #if os(tvOS)
        18
        #else
        12
        #endif
    }

    private var hasContent: Bool {
        hasAbout || !item.ratings.isEmpty || !informationGroups.isEmpty
    }

    private var hasAbout: Bool {
        nonempty(item.overview) != nil
    }

    /// `S1 · E1` for an episode, `nil` for anything else.
    private var seasonEpisodeLocator: String? {
        guard item.kind == .episode,
              let season = item.seasonNumber,
              let episode = item.episodeNumber
        else { return nil }
        return "S\(season) · E\(episode)"
    }

    @ViewBuilder
    private var aboutContent: some View {
        // Interactive ONLY when there is more overview to show.
        //
        // `plozzFocusableCard` applies `.focusable(true)` on tvOS, so wrapping a
        // Button in it produced a SECOND focusable element around the button: the
        // wrapper took focus (the oversized highlight on the whole card) and
        // swallowed Select, so the button's action never ran and the sheet never
        // appeared. It also made every About card focusable — including the ones
        // with nothing to expand.
        //
        // So when there IS something to open the card is a button whose focus
        // treatment comes from its button style; when there isn't, it keeps the
        // plain focusable-card wrapper like every other read-only section. What
        // it never does again is stack the two.
        if isOverviewTruncated {
            Button { showsFullOverview = true } label: {
                aboutCardBody
            }
            // Same lift as the read-only cards beside it. The style's default is
            // a browse-card 1.07, which on a panel this wide both mismatched its
            // neighbours and grew far enough to overlap the Ratings column.
            .buttonStyle(
                PlozzCardButtonStyle(
                    cornerRadius: cardCornerRadius,
                    focusedScale: PlozzTheme.Metrics.readOnlyFocusedCardScale
                )
            )
            .sheet(isPresented: $showsFullOverview) {
                overviewSheet
            }
        } else {
            // Read-only, but STILL FOCUSABLE — every other card on this page is,
            // and skipping over just this one reads as a dead spot. Only the
            // Button is dropped, since there is nothing to open.
            aboutCardBody
                .plozzFocusableCard(cornerRadius: cardCornerRadius)
        }
    }

    private var aboutCardBody: some View {
        Group {
            VStack(alignment: .leading, spacing: aboutContentSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // "S1 · E1" ahead of the episode's title, so the card says
                    // where in the show it sits without a separate line.
                    if let locator = seasonEpisodeLocator {
                        Text(locator)
                            .font(aboutTitleFont)
                            .plozzForeground(.secondary)
                    }
                    Text(item.title)
                        .font(aboutTitleFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let overview = nonempty(item.overview) {
                    aboutOverview(overview)
                }
            }
            // Grow to meet the ratings column when the tiles wrap past a single
            // row. `minHeight` rather than a stretch, because the target is a
            // measured number and not "whatever the row turns out to be".
            .frame(
                maxWidth: .infinity,
                minHeight: aboutTargetContentHeight,
                alignment: .topLeading
            )
            // Measure the card at its *base* cap. This is what the ratings column
            // is floored at, so it must never reflect the adjusted cap or the two
            // would chase each other.
            .background(alignment: .top) { aboutBaseHeightProbe }
            .onPreferenceChange(OverviewFullHeightKey.self) { overviewFullHeight = $0 }
            .onPreferenceChange(OverviewVisibleHeightKey.self) { overviewVisibleHeight = $0 }
            .onPreferenceChange(AboutBaseCardHeightKey.self) { aboutBaseCardHeight = $0 }
            .onPreferenceChange(BodyLineHeightKey.self) { bodyLineHeight = $0 }
            .padding(cardPadding)
        }
    }

    /// Hidden twin of the About card's content at the base line cap, plus a single
    /// line of body text. Both are pure measurements: `.hidden()` keeps them out of
    /// the render, the hit test and (on tvOS) the focus order.
    @ViewBuilder
    private var aboutBaseHeightProbe: some View {
        VStack(alignment: .leading, spacing: aboutContentSpacing) {
            Text(item.title)
                .font(aboutTitleFont)
                .fixedSize(horizontal: false, vertical: true)
            if let overview = nonempty(item.overview) {
                overviewText(overview)
                    .font(bodyFont)
                    .lineLimit(aboutBaseLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .hidden()
        .overlay {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AboutBaseCardHeightKey.self,
                    // The ratings column has no card padding of its own, so the
                    // floor it gets is the whole card, insets included.
                    value: proxy.size.height + cardPadding * 2
                )
            }
        }
        .overlay(alignment: .topLeading) {
            Text(verbatim: "Ag")
                .font(bodyFont)
                .hidden()
                .overlay {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BodyLineHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
    }

    /// Height the About card's content must reach so the card matches the ratings
    /// column. Zero (no floor) unless the ratings actually came out taller.
    private var aboutTargetContentHeight: CGFloat {
        guard aboutHeightSurplus > 0 else { return 0 }
        return ratingsBlockHeight - cardPadding * 2
    }

    /// How much taller the ratings column is than the About card would naturally
    /// be. Positive only when the tiles wrapped onto a second row.
    private var aboutHeightSurplus: CGFloat {
        guard matchesRatingsHeight, aboutBaseCardHeight > 0, ratingsBlockHeight > 0 else {
            return 0
        }
        return ratingsBlockHeight - aboutBaseCardHeight
    }

    /// The synopsis, capped to `aboutLineLimit` lines — the line count (not a fixed
    /// point height) drives the card height, so it scales correctly with Dynamic
    /// Type. When the text overflows the cap, the tail of the last visible line
    /// gradient-fades into the background and **MORE** sits inline on that line
    /// (never on a line below it). Truncation is measured (line-limited height vs
    /// full text height), so it's exact at any width or type size.
    @ViewBuilder
    private func aboutOverview(_ overview: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            overviewText(overview)
                .font(bodyFont)
                .foregroundStyle(.primary)
                .lineLimit(aboutLineLimit)
                // Measure the visible (line-limited) height…
                .background {
                    GeometryReader { limited in
                        Color.clear.preference(
                            key: OverviewVisibleHeightKey.self,
                            value: limited.size.height
                        )
                    }
                }
                // …and the height the full text wants, unconstrained.
                .background(alignment: .top) {
                    overviewText(overview)
                        .font(bodyFont)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .hidden()
                        .overlay {
                            GeometryReader { full in
                                Color.clear.preference(
                                    key: OverviewFullHeightKey.self,
                                    value: full.size.height
                                )
                            }
                        }
                }

            if isOverviewTruncated {
                // Fade the tail of the last line into the background so no glyphs
                // sit behind MORE, then draw MORE inline on that same last line.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.45),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: moreFadeWidth, height: moreFadeHeight)
                .blendMode(.destinationOut)

                Text("MORE")
                    .font(moreLabelFont)
                    .plozzForeground(.secondary)
            }
        }
        .compositingGroup()
    }

    @ViewBuilder
    private var overviewSheet: some View {
        #if os(tvOS)
        tvOverviewCard
        #else
        overviewSheetForms
        #endif
    }

    #if os(tvOS)
    /// A centred card, sized to its text — deliberately NOT the
    /// `NavigationStack` + `navigationTitle` used on iOS.
    ///
    /// tvOS renders a navigation title at display size, so a long show name was
    /// truncated to "With You and th…" while the body text sat small beneath a
    /// large empty gap. Apple's own detail overview is a plain card: title at
    /// body-ish weight, a secondary line of genres, then the overview, with the
    /// card hugging its content.
    private var tvOverviewCard: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(item.title)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if !item.genres.isEmpty {
                        Text(item.genres.prefix(3).joined(separator: ", "))
                            .font(.system(size: 26))
                            .plozzForeground(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let overview = nonempty(item.overview) {
                        overviewText(overview)
                            .font(.system(size: 29))
                            .foregroundStyle(palette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(48)
                // Measure what the text actually needs, so the card can be sized
                // to it rather than guessed at.
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: OverviewCardHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // An EXPLICIT height, between a floor and a cap.
            //
            // `fixedSize` + `maxHeight` was the wrong pairing: fixedSize forces
            // the scroll view to its ideal (full content) height and the cap then
            // clipped it, which is why the title was sliced off the top and the
            // body ran out of the bottom. Sizing it to the measured content keeps
            // a short overview hugged, and anything past the cap scrolls instead
            // of overflowing.
            .frame(
                width: 900,
                height: min(max(overviewCardHeight, 220), 760)
            )
            .onPreferenceChange(OverviewCardHeightKey.self) { overviewCardHeight = $0 }
            .background {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(palette.settingsBackground)
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
        .background(ClearSheetBackground())
    }
    #endif

    private var overviewSheetForms: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let overview = nonempty(item.overview) {
                        overviewText(overview)
                            .font(bodyFont)
                            .foregroundStyle(palette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(sheetPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
            .background(palette.settingsBackground)
            .navigationTitle(item.title)
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsFullOverview = false } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            #endif
        }
        #if !os(tvOS)
        .presentationBackground(palette.settingsBackground)
        .presentationCornerRadius(overviewSheetCornerRadius)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        // Elevation edge for dark themes, reusing the Settings sheet treatment:
        // iPhone shows only the floating top rim (sides/bottom sit at the screen
        // edge); iPad's centred card floats on all sides, so it gets a full
        // border. Light themes already separate from the page behind them.
        .overlay {
            if !palette.isLight {
                overviewSheetElevationBorder
            }
        }
        #endif
    }

    #if !os(tvOS)
    /// Corner radius pinned on the overview sheet so the elevation border traces
    /// the card's rounded edge exactly. Matches the Settings sheet.
    private var overviewSheetCornerRadius: CGFloat { 20 }

    private var isPadIdiom: Bool {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    @ViewBuilder
    private var overviewSheetElevationBorder: some View {
        let stroke = RoundedRectangle(
            cornerRadius: overviewSheetCornerRadius,
            style: .continuous
        )
        .strokeBorder(palette.overlay.border ?? .clear, lineWidth: palette.overlay.borderWidth)

        if isPadIdiom {
            // Full border: the whole card floats.
            stroke
                .ignoresSafeArea()
                .allowsHitTesting(false)
        } else {
            // Top rim only: mask so just the floating top edge shows.
            stroke
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.04),
                            .init(color: .clear, location: 0.12)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
    #endif

    /// Whether the synopsis is actually clipped — the full text wants more height
    /// than the line-limited (visible) copy. Measured, so it's exact at any width
    /// or Dynamic Type size, unlike a chars-per-line estimate.
    private var isOverviewTruncated: Bool {
        overviewVisibleHeight > 1 && overviewFullHeight > overviewVisibleHeight + 1
    }

    /// Renders the synopsis with inline markdown resolved the same way the rest of
    /// the app does: tvOS flattens `[label](url)` links to plain label text (no
    /// pointer to tap them); iOS/iPadOS renders them as tappable links.
    @ViewBuilder
    private func overviewText(_ overview: String) -> some View {
        #if os(tvOS)
        Text(verbatim: overview.overviewPlainText)
        #else
        Text(overview.overviewMarkdownWithLegibleLinks(
            textColor: palette.primaryText,
            accent: palette.accent
        ))
        #endif
    }

    private var informationGrid: some View {
        LazyVGrid(columns: informationColumns, alignment: .leading, spacing: informationRowSpacing) {
            ForEach(informationGroups) { group in
                informationGroup(group)
            }
        }
    }

    private func informationGroup(_ group: InformationGroup) -> some View {
        VStack(alignment: .leading, spacing: informationGroupSpacing) {
            Text(group.title)
                .font(informationGroupTitleFont)

            VStack(alignment: .leading, spacing: informationFactSpacing) {
                ForEach(group.facts) { fact in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(fact.label)
                            .font(factLabelFont)
                            .plozzForeground(.secondary)
                        if fact.logos.isEmpty {
                            Text(fact.value)
                                .font(factValueFont)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            WatchProviderLogoRow(
                                logos: fact.logos,
                                names: fact.value
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .plozzFocusableCard(
            cornerRadius: cardCornerRadius,
            variant: .borderless(focusPadding: cardPadding)
        )
        .accessibilityElement(children: .contain)
    }

    private func detailSection<Content: View>(
        title: LocalizedStringResource,
        contentSpacing: CGFloat = 14,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            Text(title)
                .font(sectionTitleFont)
            content()
        }
    }

    private var informationGroups: [InformationGroup] {
        [
            InformationGroup(id: "details", title: "Details", facts: detailFacts),
            InformationGroup(id: "crew", title: "Crew", facts: crewFacts),
            InformationGroup(
                id: "availability",
                title: "Release & Availability",
                facts: availabilityFacts
            ),
            InformationGroup(id: "playback", title: "Playback", facts: playbackFacts)
        ]
        .filter { !$0.facts.isEmpty }
    }

    private var sortedRatings: [ExternalRating] {
        item.ratings.sorted { $0.source.sortRank < $1.source.sortRank }
    }

    /// Every Information column occupies one third of the spine so the lower row
    /// always lines up with the top row (About · Ratings), regardless of how many
    /// groups have content.
    private var informationColumnSpan: Int { 4 }

    /// "Details" — the editorial facts about the *title* itself.
    private var detailFacts: [InformationFact] {
        var facts: [InformationFact] = []
        // The exact day when the server knows it, the bare year when it doesn't.
        // Never both: "Released 14 Apr 2019" already contains "Year 2019", and a
        // list of facts that restates one of its own entries reads as a bug.
        if let released = item.releaseDateLabel {
            facts.append(InformationFact(
                id: "released",
                label: LocalizedStringResource(
                    "mediaDetail.fact.released",
                    defaultValue: "Released",
                    comment: "Label on a movie or episode's detail page beside the date it first came out. A noun-style field label ('Released: 14 Apr 2019'), not a verb or a status."
                ),
                value: released
            ))
        } else if let year = item.productionYear {
            facts.append(InformationFact(id: "year", label: "Year", value: String(year)))
        }
        if let runtime = item.runtime?.runtimeBadgeText {
            facts.append(InformationFact(id: "runtime", label: "Runtime", value: runtime))
        }
        if let rating = nonempty(item.officialRating) {
            facts.append(InformationFact(id: "content-rating", label: "Content Rating", value: rating))
        }
        if let originalTitle = nonempty(item.originalTitle), originalTitle != item.title {
            facts.append(InformationFact(id: "original-title", label: "Original Title", value: originalTitle))
        }
        appendListFact(id: "genres", label: "Genres", values: item.genres, to: &facts)
        appendListFact(id: "tags", label: "Tags", values: Array(item.tags.prefix(16)), to: &facts)
        return facts
    }

    /// "Crew" — the people and studios behind the title (the photo cast rail above
    /// covers the on-screen cast; this carries the crew the rail doesn't).
    private var crewFacts: [InformationFact] {
        var facts: [InformationFact] = []
        appendListFact(id: "directors", label: "Directed By", values: crew(kind: "director"), to: &facts)
        appendListFact(id: "writers", label: "Written By", values: crew(kind: "writer"), to: &facts)
        appendListFact(id: "studios", label: "Studios", values: item.studios, to: &facts)
        return facts
    }

    private var availabilityFacts: [InformationFact] {
        guard let availability = externalAvailability else { return [] }
        let locale = Locale.current
        let region = locale.localizedString(
            forRegionCode: availability.regionCode
        ) ?? availability.regionCode
        var facts: [InformationFact] = []
        for event in availability.releaseEvents.sorted(by: { $0.date < $1.date }) {
            let label: LocalizedStringResource
            switch event.kind {
            case .premiere: label = "Premiere"
            case .theatricalLimited: label = "Limited Theatrical"
            case .theatrical: label = "Theatrical"
            case .digital: label = "Digital"
            case .physical: label = "Physical"
            case .television: label = "TV Premiere"
            }
            facts.append(InformationFact(
                id: "release-\(event.kind.rawValue)-\(event.date.timeIntervalSinceReferenceDate)",
                label: label,
                value: "\(event.date.formatted(.dateTime.month(.abbreviated).day().year())) · \(region)"
            ))
        }
        func offerFact(
            id: String,
            label: LocalizedStringResource,
            _ matching: (TitleWatchOffer) -> Bool
        ) -> InformationFact? {
            let offers = availability.watchOffers.filter(matching)
            let names = providerNames(offers)
            guard !names.isEmpty else { return nil }
            return InformationFact(
                id: id,
                label: label,
                value: names,
                logos: providerLogos(offers)
            )
        }
        if let fact = offerFact(id: "streaming", label: "Streaming", {
            $0.kind == .subscription || $0.kind == .free || $0.kind == .ads
        }) {
            facts.append(fact)
        }
        if let fact = offerFact(id: "rent", label: "Rent", { $0.kind == .rent }) {
            facts.append(fact)
        }
        if let fact = offerFact(id: "buy", label: "Buy", { $0.kind == .buy }) {
            facts.append(fact)
        }
        if !availability.watchOffers.isEmpty {
            facts.append(InformationFact(
                id: "availability-attribution",
                label: "Availability Data",
                value: "JustWatch"
            ))
        }
        return facts
    }

    /// Collapsed by SERVICE, not by the source's provider id.
    ///
    /// Starz sells through its own app and as an add-on channel on Apple TV, Roku
    /// and Amazon; each carries a different id, so an id-keyed dedupe listed it four
    /// times and pushed the genuinely different services off the end of the line.
    /// One mark per SERVICE, in the source's order, collapsed the same way the
    /// names are so the logo row and the text fallback can never disagree.
    private func providerLogos(_ offers: [TitleWatchOffer]) -> [WatchProviderLogo] {
        var seen = Set<String>()
        return offers.compactMap { offer in
            let name = ExternalTitleAvailability.collapsedServiceName(offer.providerName)
            guard seen.insert(name).inserted, let url = offer.logoURL else { return nil }
            return WatchProviderLogo(id: name, name: name, url: url)
        }
    }

    private func providerNames(_ offers: [TitleWatchOffer]) -> String {
        var seen = Set<String>()
        return offers
            .map { ExternalTitleAvailability.collapsedServiceName($0.providerName) }
            .filter { seen.insert($0).inserted }
            .joined(separator: " · ")
    }

    /// "Playback" — everything about *this copy* in one place: where it streams
    /// from, and the selected version's quality + file facts. Replaces the old
    /// overlapping Playback/Source/File split (Quality vs Version vs Source, Runtime
    /// vs Duration, a "Size" that was really the bitrate).
    private var playbackFacts: [InformationFact] {
        var facts: [InformationFact] = []
        if let selectedSource {
            facts.append(InformationFact(id: "server", label: "Server", value: selectedSource.displayName))
            if let locality = localityLabel(selectedSource.locality) {
                facts.append(InformationFact(id: "connection", label: "Connection", value: locality))
            }
            if let account = nonempty(selectedSource.accountName),
               !selectedSource.displayName.localizedCaseInsensitiveContains(account) {
                facts.append(InformationFact(id: "account", label: "Account", value: account))
            }
        }
        if let selectedVersion {
            if let edition = nonempty(selectedVersion.editionLabel) {
                facts.append(InformationFact(id: "edition", label: "Edition", value: edition))
            }
            let quality = [selectedVersion.resolutionLabel, selectedVersion.hdrLabel, selectedVersion.audioLabel]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !quality.isEmpty {
                facts.append(InformationFact(id: "quality", label: "Quality", value: quality))
            }
            if let source = nonempty(selectedVersion.sourceQualityLabel) {
                facts.append(InformationFact(id: "source", label: "Source", value: source))
            }
            if let bitrate = nonempty(selectedVersion.bitrateLabel) {
                facts.append(InformationFact(id: "bitrate", label: "Bitrate", value: bitrate))
            }
            if let size = nonempty(selectedVersion.sizeLabel) {
                facts.append(InformationFact(id: "size", label: "Size", value: size))
            }
            if let filename = nonempty(selectedVersion.fileName) {
                facts.append(InformationFact(id: "filename", label: "File", value: filename))
            }
        }
        return facts
    }

    private func appendVersionFact(
        id: String,
        label: LocalizedStringResource,
        value: String?,
        alwaysInclude: Bool = false,
        to facts: inout [InformationFact]
    ) {
        guard let value = nonempty(value) else { return }
        if !alwaysInclude, selectedVersion?.displayLabel?.localizedCaseInsensitiveContains(value) == true {
            return
        }
        facts.append(InformationFact(id: id, label: label, value: value))
    }

    private func localityLabel(_ locality: SourceLocality?) -> String? {   // l10n:content — source locality detail from the provider
        switch locality {
        case .local: return "Local network"
        case .remote: return "Remote"
        case .unknown, nil: return nil
        }
    }

    private func appendListFact(
        id: String,
        label: LocalizedStringResource,
        values: [String],
        to facts: inout [InformationFact]
    ) {
        let unique = orderedUnique(values)
        guard !unique.isEmpty else { return }
        facts.append(InformationFact(
            id: id,
            label: label,
            value: ListFormatter.localizedString(byJoining: unique)
        ))
    }

    private func crew(kind: String) -> [String] {
        item.people.compactMap { person in
            person.kind?.caseInsensitiveCompare(kind) == .orderedSame ? person.name : nil
        }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? trimmed : nil
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var informationColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: informationColumnMinimumWidth),
                spacing: informationColumnSpacing,
                alignment: .top
            )
        ]
    }

    private var sectionTitleFont: Font {
        #if os(tvOS)
        .system(size: 34, weight: .bold)
        #else
        .title2.bold()
        #endif
    }

    private var bodyFont: Font {
        #if os(tvOS)
        .system(size: 24)
        #else
        .body
        #endif
    }

    private var aboutTitleFont: Font {
        #if os(tvOS)
        .system(size: 28, weight: .semibold)
        #else
        .title3.weight(.semibold)
        #endif
    }

    private var aboutContentSpacing: CGFloat {
        #if os(tvOS)
        12
        #else
        10
        #endif
    }

    /// Lines of synopsis to show.
    ///
    /// The base cap is what sets the About card's height, and therefore the height
    /// the ratings tiles grow to meet — so it stays a real, tight cap and MORE
    /// still appears the moment anything is hidden. It is only raised when the
    /// ratings column came out *taller* (the tiles wrapped onto a second row): the
    /// card has to grow to match, so it fills the extra with text rather than blank
    /// space. `floor` on the surplus keeps the text inside the height it is
    /// matching, so the card can never overshoot the column beside it.
    private var aboutLineLimit: Int {
        aboutBaseLineLimit + extraAboutLines
    }

    private var aboutBaseLineLimit: Int {
        #if os(tvOS)
        return 6
        #else
        return horizontalSizeClass == .regular ? 6 : 7
        #endif
    }

    private var extraAboutLines: Int {
        guard bodyLineHeight > 1, aboutHeightSurplus > 0 else { return 0 }
        // Bounded by the surplus itself, which is bounded by the number of rating
        // rows — the card can grow to meet the tiles and no further.
        return Int((aboutHeightSurplus / bodyLineHeight).rounded(.down))
    }

    private var moreLabelFont: Font {
        #if os(tvOS)
        .system(size: 20, weight: .semibold)
        #else
        .footnote.weight(.semibold)
        #endif
    }

    private var moreFadeHeight: CGFloat {
        #if os(tvOS)
        34
        #else
        22
        #endif
    }

    private var moreFadeWidth: CGFloat {
        #if os(tvOS)
        220
        #else
        150
        #endif
    }

    private var sheetPadding: CGFloat {
        #if os(tvOS)
        60
        #else
        24
        #endif
    }

    private var factLabelFont: Font {
        #if os(tvOS)
        .system(size: 18, weight: .semibold)
        #else
        .caption.weight(.semibold)
        #endif
    }

    private var factValueFont: Font {
        #if os(tvOS)
        .system(size: 23, weight: .medium)
        #else
        .body.weight(.medium)
        #endif
    }

    private var informationGroupTitleFont: Font {
        // Match the top-level section headers (About/Ratings) so Details, Playback
        // and File each read as their own distinct section — the "Information"
        // umbrella header is gone, so these carry the separation.
        sectionTitleFont
    }

    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        36
        #else
        28
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        18
        #else
        12
        #endif
    }

    private var informationColumnSpacing: CGFloat {
        #if os(tvOS)
        54
        #else
        24
        #endif
    }

    /// Vertical gap between Information sections when they wrap to a new row
    /// (File under Details on a 2-column iPad, or all stacked on iPhone). Larger
    /// than the column gutter so a wrapped section's large header is clearly the
    /// start of a new section, not a continuation of the column above.
    private var informationRowSpacing: CGFloat {
        #if os(tvOS)
        36
        #else
        28
        #endif
    }

    private var informationGroupSpacing: CGFloat {
        #if os(tvOS)
        22
        #else
        16
        #endif
    }

    private var informationFactSpacing: CGFloat {
        #if os(tvOS)
        18
        #else
        14
        #endif
    }

    private var ratingRowSpacing: CGFloat {
        #if os(tvOS)
        16
        #else
        12
        #endif
    }

    private var cardPadding: CGFloat {
        #if os(tvOS)
        22
        #else
        16
        #endif
    }

    private var cardCornerRadius: CGFloat {
        #if os(tvOS)
        20
        #else
        16
        #endif
    }

    private var informationColumnMinimumWidth: CGFloat {
        #if os(tvOS)
        400
        #else
        280
        #endif
    }
}

private struct OverviewFullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct OverviewVisibleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AboutBaseCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RatingsBlockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BodyLineHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A wrapping row of service marks.
///
/// Wrapping rather than scrolling: this sits inside a static information column
/// that nothing focuses through, so a horizontal scroller would hide services with
/// no affordance to reveal them.
private struct WatchProviderLogoRow: View {
    let logos: [WatchProviderLogo]
    /// The same services as text, used as the single accessibility label — a
    /// screen reader should hear "Starz, Philo, YouTube TV", not twelve images.
    let names: String

    #if os(tvOS)
    private static let side: CGFloat = 64
    #else
    private static let side: CGFloat = 46
    #endif

    var body: some View {
        WrappingHStackLayout(spacing: 10, lineSpacing: 10) {
            ForEach(logos) { logo in
                FallbackAsyncImage(
                    urls: [logo.url],
                    variant: .serviceLogo
                ) {
                    // Never a blank tile: an unreachable logo falls back to the
                    // service's own name rather than a grey square.
                    Text(logo.name)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(4)
                }
                .frame(width: Self.side, height: Self.side)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(names))
    }
}

private struct InformationGroup: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let facts: [InformationFact]
}

private struct InformationFact: Identifiable {
    let id: String
    /// `LocalizedStringResource`, not `LocalizedStringKey`, so a label that needs
    /// a translator note can carry one. Several of these are ambiguous out of
    /// context — "Released" reads as a past-tense verb as easily as a date label,
    /// and "Rent" is a verb in English and a noun in half the languages we ship.
    /// Bare string literals still work at the call site.
    let label: LocalizedStringResource
    let value: String
    /// Service artwork for a "where to watch" row. A logo is read at a glance from
    /// across a room where a list of names has to be parsed, so where these exist
    /// they replace the text — `value` stays as the accessibility description and
    /// as the fallback when a logo is missing.
    var logos: [WatchProviderLogo] = []
}

/// One service's mark. Identified by the collapsed service NAME rather than the
/// source's provider id, so Starz billed through four storefronts shows one logo.
struct WatchProviderLogo: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

#endif
