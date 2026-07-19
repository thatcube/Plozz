#if os(iOS)
import CoreModels
import FeatureHomeCore
import SwiftUI

struct PlozziOSItemDetailView: View {
    @State private var viewModel: ItemDetailViewModel

    init(provider: any MediaProvider, item: MediaItem) {
        _viewModel = State(
            initialValue: ItemDetailViewModel(
                provider: provider,
                itemID: item.id,
                initialItem: item,
                sourceAccountID: item.sourceAccountID
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading details…")
            case .empty:
                ContentUnavailableView(
                    "Details unavailable",
                    systemImage: "film.stack"
                )
            case let .loaded(detail):
                detailContent(detail)
            case let .failed(error):
                ContentUnavailableView {
                    Label("Unable to load details", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.reload() }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    private func detailContent(_ detail: ItemDetailViewModel.Detail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PlozziOSDetailHero(item: detail.item)

                if detail.item.kind == .series, !detail.children.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Seasons")
                            .font(.title2.bold())

                        ForEach(detail.children) { season in
                            NavigationLink {
                                PlozziOSSeasonEpisodesView(
                                    viewModel: viewModel,
                                    season: season
                                )
                            } label: {
                                PlozziOSSeasonRow(season: season)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !detail.item.people.filter(\.isCast).isEmpty {
                    PlozziOSCastSection(people: detail.item.people.filter(\.isCast))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle(detail.item.title)
    }
}

private struct PlozziOSDetailHero: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: item.backdropURL ?? item.posterURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(.secondary.opacity(0.14))
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Text(item.title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .padding()
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))

            if !metadata.isEmpty {
                Text(metadata.joined(separator: "  •  "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .textSelection(.enabled)
            }

            if !item.genres.isEmpty {
                Text(item.genres.prefix(4).joined(separator: "  •  "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metadata: [String] {
        var values: [String] = []
        if let year = item.productionYear {
            values.append(year.formatted())
        }
        if let rating = item.officialRating, !rating.isEmpty {
            values.append(rating)
        }
        if let runtime = item.runtime, runtime > 0 {
            let minutes = Int(runtime / 60)
            values.append("\(minutes / 60)h \(minutes % 60)m")
        }
        return values
    }
}

private struct PlozziOSSeasonRow: View {
    let season: MediaItem

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: season.posterURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 72, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(season.title)
                .font(.headline)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct PlozziOSSeasonEpisodesView: View {
    let viewModel: ItemDetailViewModel
    let season: MediaItem

    var body: some View {
        Group {
            if let episodes = viewModel.episodes(for: season.id) {
                if episodes.isEmpty {
                    ContentUnavailableView(
                        "No episodes",
                        systemImage: "play.rectangle"
                    )
                } else {
                    List(episodes) { episode in
                        PlozziOSEpisodeRow(episode: episode)
                    }
                    .listStyle(.plain)
                }
            } else {
                ProgressView("Loading episodes…")
            }
        }
        .navigationTitle(season.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadEpisodes(for: season.id) }
    }
}

private struct PlozziOSEpisodeRow: View {
    let episode: MediaItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: episode.backdropURL ?? episode.posterURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.secondary.opacity(0.14))
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(episode.episodeLabel)
                    .font(.headline)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PlozziOSCastSection: View {
    let people: [MediaPerson]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .font(.title2.bold())

            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(people.prefix(20)) { person in
                        VStack(alignment: .leading, spacing: 6) {
                            AsyncImage(url: person.imageURL) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                Circle()
                                    .fill(.secondary.opacity(0.14))
                                    .overlay {
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(.secondary)
                                    }
                            }
                            .frame(width: 82, height: 82)
                            .clipShape(Circle())

                            Text(person.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                            if let role = person.role {
                                Text(role)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 96, alignment: .leading)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private extension MediaItem {
    var episodeLabel: String {
        if let episodeNumber {
            return "Episode \(episodeNumber): \(title)"
        }
        return title
    }
}
#endif
