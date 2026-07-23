#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Shared title-level detail sections. Platform shells keep their own Cast rail
/// first, then place this view beneath it so content and ordering stay identical
/// while the adaptive grids naturally collapse on iPhone.
public struct DetailInformationSections: View {
    private let item: MediaItem
    private let horizontalInset: CGFloat

    public init(item: MediaItem, horizontalInset: CGFloat) {
        self.item = item
        self.horizontalInset = horizontalInset
    }

    public var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: sectionSpacing) {
                if hasAbout {
                    detailSection(title: "About") {
                        aboutContent
                    }
                }
                if !item.ratings.isEmpty {
                    detailSection(title: "Ratings") {
                        ratingsGrid
                    }
                }
                if !informationFacts.isEmpty {
                    detailSection(title: "Information") {
                        informationGrid
                    }
                }
            }
            .padding(.horizontal, horizontalInset)
        }
    }

    private var hasContent: Bool {
        hasAbout || !item.ratings.isEmpty || !informationFacts.isEmpty
    }

    private var hasAbout: Bool {
        item.tagline != nil || nonempty(item.overview) != nil
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let tagline = item.tagline {
                Text(tagline)
                    .font(taglineFont)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            if let overview = nonempty(item.overview) {
                Text(overview)
                    .font(bodyFont)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(cardPadding)
        .background(cardBackground)
    }

    private var ratingsGrid: some View {
        LazyVGrid(columns: ratingColumns, alignment: .leading, spacing: gridSpacing) {
            ForEach(item.ratings.sorted { $0.source.sortRank < $1.source.sortRank }) { rating in
                DetailedRatingCard(rating: rating)
            }
        }
    }

    private var informationGrid: some View {
        LazyVGrid(columns: informationColumns, alignment: .leading, spacing: gridSpacing) {
            ForEach(informationFacts) { fact in
                VStack(alignment: .leading, spacing: 7) {
                    Text(fact.label)
                        .font(factLabelFont)
                        .foregroundStyle(.secondary)
                    Text(fact.value)
                        .font(factValueFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: factMinimumHeight, alignment: .topLeading)
                .padding(cardPadding)
                .background(cardBackground)
            }
        }
    }

    private func detailSection<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(sectionTitleFont)
            content()
        }
    }

    private var informationFacts: [InformationFact] {
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

    private var ratingColumns: [GridItem] {
        [GridItem(.adaptive(minimum: ratingCardMinimumWidth), spacing: gridSpacing)]
    }

    private var informationColumns: [GridItem] {
        [GridItem(.adaptive(minimum: informationCardMinimumWidth), spacing: gridSpacing)]
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
    }

    private var sectionTitleFont: Font {
        #if os(tvOS)
        .system(size: 34, weight: .bold)
        #else
        .title2.bold()
        #endif
    }

    private var taglineFont: Font {
        #if os(tvOS)
        .system(size: 25, weight: .medium)
        #else
        .title3.weight(.medium)
        #endif
    }

    private var bodyFont: Font {
        #if os(tvOS)
        .system(size: 24)
        #else
        .body
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

    private var ratingCardMinimumWidth: CGFloat {
        #if os(tvOS)
        330
        #else
        250
        #endif
    }

    private var informationCardMinimumWidth: CGFloat {
        #if os(tvOS)
        320
        #else
        250
        #endif
    }

    private var factMinimumHeight: CGFloat {
        #if os(tvOS)
        80
        #else
        56
        #endif
    }
}

private struct InformationFact: Identifiable {
    let id: String
    let label: LocalizedStringKey
    let value: String
}

private struct DetailedRatingCard: View {
    let rating: ExternalRating

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(rating.source.displayName)
                    .font(titleFont)
                Spacer()
                RatingBadge(rating: rating)
            }
            HStack(spacing: 12) {
                Text(cohortLabel)
                if let count = rating.ratingCount, count > 0 {
                    Text("\(count.formatted()) ratings")
                }
                if let verdict = rating.verdict {
                    Label(verdict.displayName, systemImage: verdictSymbol(verdict))
                }
            }
            .font(detailFont)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        .padding(cardPadding)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
        )
        .accessibilityElement(children: .combine)
    }

    private var cohortLabel: LocalizedStringKey {
        switch rating.cohort {
        case .critics: return "Critics"
        case .audience: return "Audience"
        case .community: return "Community"
        }
    }

    private func verdictSymbol(_ verdict: RatingVerdict) -> String {
        switch verdict {
        case .fresh, .hot, .positive: return "hand.thumbsup.fill"
        case .rotten, .stale, .negative: return "hand.thumbsdown.fill"
        }
    }

    private var titleFont: Font {
        #if os(tvOS)
        .system(size: 24, weight: .semibold)
        #else
        .headline
        #endif
    }

    private var detailFont: Font {
        #if os(tvOS)
        .system(size: 18)
        #else
        .caption
        #endif
    }

    private var minimumHeight: CGFloat {
        #if os(tvOS)
        92
        #else
        68
        #endif
    }

    private var cardPadding: CGFloat {
        #if os(tvOS)
        22
        #else
        16
        #endif
    }

    private var cornerRadius: CGFloat {
        #if os(tvOS)
        20
        #else
        16
        #endif
    }
}

#endif
