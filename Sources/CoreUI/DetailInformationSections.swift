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
                .background(palette.informationSurface)
        }
    }

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
        if matchesRatingsHeight {
            // Side-by-side with About: a single row of equal-width tiles that fill
            // the grid row's height, so they bottom-align with the About card. The
            // Grid row is sized to the taller of {About, tiles}, and both cells fill
            // it — so About drives the height when the synopsis is long, and the
            // tiles drive it when the synopsis is short. No manual measurement, and
            // it stays bounded because it's inside a Grid (not a raw ScrollView).
            HStack(spacing: ratingsTileSpacing) {
                ForEach(sortedRatings) { rating in
                    RatingTile(rating: rating)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // Stacked (iPhone): wrap naturally, tiles keep their square height.
            LazyVGrid(columns: ratingsTileColumns, alignment: .leading, spacing: ratingsTileSpacing) {
                ForEach(sortedRatings) { rating in
                    RatingTile(rating: rating)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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

    private var ratingsTileColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: ratingsTileMinWidth, maximum: ratingsTileMaxWidth),
                spacing: ratingsTileSpacing,
                alignment: .top
            )
        ]
    }

    private var ratingsTileMinWidth: CGFloat {
        #if os(tvOS)
        210
        #else
        horizontalSizeClass == .compact ? 130 : 150
        #endif
    }

    private var ratingsTileMaxWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        horizontalSizeClass == .compact ? 200 : 230
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

    private var aboutContent: some View {
        Button { showsFullOverview = true } label: {
            VStack(alignment: .leading, spacing: aboutContentSpacing) {
                Text(item.title)
                    .font(aboutTitleFont)
                    .fixedSize(horizontal: false, vertical: true)
                if let overview = nonempty(item.overview) {
                    aboutOverview(overview)
                }
            }
            // Fill the grid row height when side-by-side with Ratings, so a short
            // synopsis's card still grows to match the tiles (content stays pinned
            // to the top). Natural height when stacked on iPhone.
            .frame(
                maxWidth: .infinity,
                maxHeight: matchesRatingsHeight ? .infinity : nil,
                alignment: .topLeading
            )
            .onPreferenceChange(OverviewFullHeightKey.self) { overviewFullHeight = $0 }
            .onPreferenceChange(OverviewVisibleHeightKey.self) { overviewVisibleHeight = $0 }
            .padding(cardPadding)
        }
        .buttonStyle(.plain)
        .plozzFocusableCard(cornerRadius: cardCornerRadius)
        .sheet(isPresented: $showsFullOverview) {
            overviewSheet
        }
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
                    .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
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

    /// Line cap for the About synopsis. Sized so the About card is a touch taller
    /// than a single row of rating tiles, so the ratings column grows to match About
    /// (keeping the tiles square) rather than About having to shrink. The line count
    /// — not a fixed height — drives the card, so it scales with Dynamic Type.
    private var aboutLineLimit: Int {
        #if os(tvOS)
        6
        #else
        horizontalSizeClass == .regular ? 6 : 7
        #endif
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
