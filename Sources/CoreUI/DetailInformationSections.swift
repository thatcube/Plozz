#if canImport(SwiftUI)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

/// Shared title-level detail sections. Platform shells keep their own Cast rail
/// first, then place this view beneath it so content and ordering stay identical
/// while the adaptive grids naturally collapse on iPhone.
public struct DetailInformationSections: View {
    private let item: MediaItem
    private let horizontalInset: CGFloat
    private let selectedSource: MediaSourceRef?
    private let selectedVersion: MediaVersion?

    @State private var showsFullOverview = false
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
        selectedVersion: MediaVersion? = nil
    ) {
        self.item = item
        self.horizontalInset = horizontalInset
        self.selectedSource = selectedSource
        self.selectedVersion = selectedVersion
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
                detailSection(title: "About") { aboutContent }
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
                        headedSection(title: "About") { aboutContent }
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
        title: LocalizedStringKey,
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

    private var aboutContent: some View {
        Button { showsFullOverview = true } label: {
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
        .buttonStyle(.plain)
        .plozzFocusableCard(cornerRadius: cardCornerRadius)
        .sheet(isPresented: $showsFullOverview) {
            overviewSheet
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

    private var overviewSheet: some View {
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
                        Text(fact.value)
                            .font(factValueFont)
                            .fixedSize(horizontal: false, vertical: true)
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
        title: LocalizedStringKey,
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
        if let year = item.productionYear {
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
        label: LocalizedStringKey,
        value: String?,
        alwaysInclude: Bool = false,
        to facts: inout [InformationFact]
    ) {
        guard let value = nonempty(value) else { return }
        if !alwaysInclude, selectedVersion?.displayLabel.localizedCaseInsensitiveContains(value) == true {
            return
        }
        facts.append(InformationFact(id: id, label: label, value: value))
    }

    private func localityLabel(_ locality: SourceLocality?) -> String? {
        switch locality {
        case .local: return "Local network"
        case .remote: return "Remote"
        case .unknown, nil: return nil
        }
    }

    private func appendListFact(
        id: String,
        label: LocalizedStringKey,
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

private struct InformationGroup: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let facts: [InformationFact]
}

private struct InformationFact: Identifiable {
    let id: String
    let label: LocalizedStringKey
    let value: String
}

#endif
