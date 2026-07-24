#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Shared title-level detail sections. Platform shells keep their own Cast rail
/// first, then place this view beneath it so content and ordering stay identical
/// while the adaptive grids naturally collapse on iPhone.
public struct DetailInformationSections: View {
    private let item: MediaItem
    private let horizontalInset: CGFloat
    private let selectedSource: MediaSourceRef?
    private let selectedVersion: MediaVersion?

    @State private var showsFullOverview = false

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
            #if os(tvOS)
            tvGrid
                .padding(.horizontal, horizontalInset)
            #else
            iOSLayout
                .padding(.horizontal, horizontalInset)
            #endif
        }
    }

    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var iOSLayout: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            if horizontalSizeClass == .regular {
                // iPad: side-by-side About + Ratings, matching tvOS spine
                if hasAbout || !item.ratings.isEmpty {
                    HStack(alignment: .top, spacing: gridSpacing) {
                        if hasAbout {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("About")
                                    .font(sectionTitleFont)
                                aboutContent
                            }
                            .frame(maxWidth: .infinity)
                        }
                        if !item.ratings.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Ratings")
                                    .font(sectionTitleFont)
                                compactRatingsCard
                            }
                            .frame(maxWidth: hasAbout ? nil : .infinity)
                            .frame(width: hasAbout ? iPadRatingsWidth : nil)
                        }
                    }
                }
            } else {
                // iPhone: vertical stack
                if hasAbout {
                    detailSection(title: "About") {
                        aboutContent
                    }
                }
                if !item.ratings.isEmpty {
                    detailSection(title: "Ratings") {
                        compactRatingsCard
                    }
                }
            }
            if !informationGroups.isEmpty {
                detailSection(title: "Information", contentSpacing: informationHeaderSpacing) {
                    informationGrid
                }
            }
        }
    }

    private var iPadRatingsWidth: CGFloat { 320 }

    private var compactRatingsCard: some View {
        VStack(alignment: .leading, spacing: ratingRowSpacing) {
            ForEach(sortedRatings) { rating in
                HStack(spacing: 14) {
                    Text(rating.source.displayName)
                        .font(factValueFont)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    RatingBadge(rating: rating)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(cardPadding)
        .plozzFocusableCard(cornerRadius: cardCornerRadius)
        .accessibilityElement(children: .contain)
    }
    #endif

    #if os(tvOS)
    private var tvGrid: some View {
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
                            .gridCellColumns(8)
                        if !item.ratings.isEmpty {
                            headedSection(title: "Ratings") { ratingsCard }
                                .gridCellColumns(4)
                        } else {
                            Color.clear.gridCellColumns(4)
                        }
                    } else {
                        headedSection(title: "Ratings") { ratingsCard }
                            .gridCellColumns(4)
                        Color.clear.gridCellColumns(8)
                    }
                }
            }

            if !informationGroups.isEmpty {
                GridRow {
                    Text("Information")
                        .font(sectionTitleFont)
                        .gridCellColumns(12)
                }
                .padding(.top, sectionSpacing)

                GridRow(alignment: .top) {
                    ForEach(informationGroups) { group in
                        informationGroup(group)
                            // Reserve the borderless focus plate's outward growth
                            // (cardPadding on each side) plus an extra 8pt so a
                            // focused column's plate lands just inside its own
                            // keyline with a clear gap to the neighbouring column.
                            .padding(.trailing, cardPadding + 8)
                            .gridCellColumns(informationColumnSpan)
                    }
                    if informationGroups.count * informationColumnSpan < 12 {
                        Color.clear
                            .gridCellColumns(12 - informationGroups.count * informationColumnSpan)
                    }
                }
                .padding(.top, informationHeaderSpacing)
            }
        }
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

    private var ratingsCard: some View {
        VStack(alignment: .leading, spacing: ratingRowSpacing) {
            ForEach(sortedRatings) { rating in
                HStack(spacing: 14) {
                    Text(rating.source.displayName)
                        .font(factValueFont)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    RatingBadge(rating: rating)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(cardPadding)
        .plozzFocusableCard(cornerRadius: cardCornerRadius)
        .accessibilityElement(children: .contain)
    }
    #endif

    private var hasContent: Bool {
        hasAbout || !item.ratings.isEmpty || !informationGroups.isEmpty
    }

    private var hasAbout: Bool {
        nonempty(item.overview) != nil
    }

    private var aboutContent: some View {
        Button { showsFullOverview = true } label: {
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: aboutContentSpacing) {
                    Text(item.title)
                        .font(aboutTitleFont)
                        .fixedSize(horizontal: false, vertical: true)
                    if let overview = nonempty(item.overview) {
                        overviewText(overview)
                            .font(bodyFont)
                            .foregroundStyle(.primary)
                            .lineLimit(aboutLineLimit)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: cardFillHeight, alignment: .topLeading)

                if overviewExceedsLimit {
                    // Fade the text behind MORE so it doesn't collide
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 120, height: moreFadeHeight)
                    .blendMode(.destinationOut)

                    Text("MORE")
                        .font(moreLabelFont)
                        .foregroundStyle(.secondary)
                }
            }
            .compositingGroup()
            .padding(cardPadding)
        }
        .buttonStyle(.plain)
        .plozzFocusableCard(cornerRadius: cardCornerRadius)
        #if os(tvOS)
        .sheet(isPresented: $showsFullOverview) {
            overviewSheet
        }
        #else
        .sheet(isPresented: $showsFullOverview) {
            overviewSheet
        }
        #endif
    }

    private var overviewSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let overview = nonempty(item.overview) {
                        overviewText(overview)
                            .font(bodyFont)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(sheetPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(item.title)
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { showsFullOverview = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            #endif
        }
    }

    private var overviewExceedsLimit: Bool {
        guard let overview = nonempty(item.overview) else { return false }
        // Heuristic: more than ~aboutLineLimit lines of text at ~70 chars/line
        return overview.count > aboutLineLimit * 70
    }

    /// Renders the synopsis with inline markdown resolved the same way the rest of
    /// the app does: tvOS flattens `[label](url)` links to plain label text (no
    /// pointer to tap them); iOS/iPadOS renders them as tappable links.
    @ViewBuilder
    private func overviewText(_ overview: String) -> some View {
        #if os(tvOS)
        Text(verbatim: overview.overviewPlainText)
        #else
        Text(overview.overviewMarkdown ?? AttributedString(overview))
        #endif
    }

    private var informationGrid: some View {
        LazyVGrid(columns: informationColumns, alignment: .leading, spacing: gridSpacing) {
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
            InformationGroup(id: "playback", title: "Playback", facts: playbackFacts),
            InformationGroup(id: "file", title: "File", facts: fileFacts)
        ]
        .filter { !$0.facts.isEmpty }
    }

    private var sortedRatings: [ExternalRating] {
        item.ratings.sorted { $0.source.sortRank < $1.source.sortRank }
    }

    private var informationColumnSpan: Int {
        switch informationGroups.count {
        case 1: 8
        case 2: 6
        default: 4
        }
    }

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
        appendListFact(id: "studios", label: "Studios", values: item.studios, to: &facts)
        appendListFact(id: "directors", label: "Directed By", values: crew(kind: "director"), to: &facts)
        appendListFact(id: "writers", label: "Written By", values: crew(kind: "writer"), to: &facts)
        appendListFact(id: "tags", label: "Tags", values: Array(item.tags.prefix(16)), to: &facts)
        return facts
    }

    private var playbackFacts: [InformationFact] {
        var facts: [InformationFact] = []
        if let selectedSource {
            facts.append(InformationFact(id: "server", label: "Server", value: selectedSource.displayName))
            if let provider = selectedSource.providerKind?.displayName,
               !selectedSource.displayName.localizedCaseInsensitiveContains(provider) {
                facts.append(InformationFact(id: "provider", label: "Provider", value: provider))
            }
            if let account = nonempty(selectedSource.accountName),
               !selectedSource.displayName.localizedCaseInsensitiveContains(account) {
                facts.append(InformationFact(id: "account", label: "Account", value: account))
            }
            if let locality = localityLabel(selectedSource.locality) {
                facts.append(InformationFact(id: "connection", label: "Connection", value: locality))
            }
        }
        if let selectedVersion, selectedVersion.displayLabel != "Version" {
            facts.append(InformationFact(id: "version", label: "Version", value: selectedVersion.displayLabel))
        }
        return facts
    }

    private var fileFacts: [InformationFact] {
        guard let selectedVersion else { return [] }
        var facts: [InformationFact] = []
        appendVersionFact(id: "filename", label: "Filename", value: selectedVersion.fileName, alwaysInclude: true, to: &facts)
        appendVersionFact(id: "resolution", label: "Resolution", value: selectedVersion.resolutionLabel, to: &facts)
        appendVersionFact(id: "dynamic-range", label: "Dynamic Range", value: selectedVersion.hdrLabel, to: &facts)
        appendVersionFact(id: "source-quality", label: "Source", value: selectedVersion.sourceQualityLabel, to: &facts)
        appendVersionFact(id: "audio", label: "Audio", value: selectedVersion.audioLabel, to: &facts)
        appendVersionFact(id: "bitrate", label: "Bitrate", value: selectedVersion.bitrateLabel, to: &facts)
        appendVersionFact(id: "size", label: "Size", value: selectedVersion.sizeLabel, to: &facts)
        appendVersionFact(id: "file-duration", label: "Duration", value: selectedVersion.durationLabel, to: &facts)
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

    private var aboutLineLimit: Int {
        #if os(tvOS)
        5
        #else
        4
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

    private var sheetPadding: CGFloat {
        #if os(tvOS)
        60
        #else
        24
        #endif
    }

    private var cardFillHeight: CGFloat? {
        #if os(tvOS)
        .infinity
        #else
        nil
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
        #if os(tvOS)
        .system(size: 26, weight: .semibold)
        #else
        .headline
        #endif
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

    private var informationHeaderSpacing: CGFloat {
        #if os(tvOS)
        cardPadding + 4
        #else
        14
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
