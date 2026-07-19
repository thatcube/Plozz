#if os(iOS)
import CoreModels
import FeatureHomeCore
import Observation
import SwiftUI

@MainActor
@Observable
final class PlozziOSLibrariesModel {
    private(set) var state: LoadState<[MediaLibrary]> = .idle

    func load(provider: (any MediaProvider)?) async {
        guard let provider else {
            state = .empty
            return
        }
        state = .loading
        do {
            let libraries = try await provider.libraries()
                .filter { !$0.isMusic }
            state = libraries.isEmpty ? .empty : .loaded(libraries)
        } catch is CancellationError {
            return
        } catch let error as AppError {
            state = .failed(error)
        } catch {
            state = .failed(.unknown(error.localizedDescription))
        }
    }
}

struct PlozziOSLibrariesView: View {
    @State private var model = PlozziOSLibrariesModel()

    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView("Loading libraries…")
            case .empty:
                ContentUnavailableView {
                    Label("No video libraries", systemImage: "rectangle.stack")
                } description: {
                    Text("This server did not return any movie or TV libraries.")
                }
            case let .loaded(libraries):
                PlozziOSLibraryList(
                    libraries: libraries,
                    provider: appModel.accountsProviders.primaryProvider,
                    settings: appModel.settings
                )
            case let .failed(error):
                ContentUnavailableView {
                    Label("Unable to load libraries", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await model.load(
                                provider: appModel.accountsProviders.primaryProvider
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Server", systemImage: "plus", action: onAddServer)
            }
        }
        .task(id: appModel.accounts.map(\.credentialRevision)) {
            await model.load(provider: appModel.accountsProviders.primaryProvider)
        }
    }
}

private struct PlozziOSLibraryList: View {
    let libraries: [MediaLibrary]
    let provider: (any MediaProvider)?
    let settings: PlozziOSSettingsModel

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 16)
                ],
                spacing: 16
            ) {
                ForEach(libraries) { library in
                    if let provider {
                        NavigationLink {
                            PlozziOSLibraryGridView(
                                viewModel: LibraryBrowseViewModel(
                                    provider: provider,
                                    containerID: library.id,
                                    containerKind: library.kind,
                                    sourceAccountID: library.sourceAccountID
                                ),
                                title: library.title,
                                provider: provider,
                                settings: settings
                            )
                        } label: {
                            PlozziOSLibraryCard(library: library)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }
}

private struct PlozziOSLibraryCard: View {
    let library: MediaLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: library.imageURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: library.kind == .series ? "tv" : "film")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text(library.title)
                .font(.headline)
                .lineLimit(2)
        }
        .contentShape(Rectangle())
    }
}

struct PlozziOSLibraryGridView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: LibraryBrowseViewModel
    private let title: String
    private let provider: any MediaProvider
    private let settings: PlozziOSSettingsModel

    init(
        viewModel: LibraryBrowseViewModel,
        title: String,
        provider: any MediaProvider,
        settings: PlozziOSSettingsModel
    ) {
        _viewModel = State(initialValue: viewModel)
        self.title = title
        self.provider = provider
        self.settings = settings
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading \(title)…")
            case .empty:
                ContentUnavailableView(
                    "This library is empty",
                    systemImage: "rectangle.stack"
                )
            case let .loaded(total):
                if total == 0 {
                    ContentUnavailableView(
                        "This library is empty",
                        systemImage: "rectangle.stack"
                    )
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: settings.density.density.iOSPosterGridColumns(
                                horizontalSizeClass: horizontalSizeClass
                            ),
                            spacing: 18
                        ) {
                            ForEach(0..<total, id: \.self) { index in
                                PlozziOSLibraryItemCell(
                                    slot: viewModel.slot(at: index),
                                    index: index,
                                    provider: provider,
                                    cardStyle: settings.cardStyle.style,
                                    watchIndicator: settings.watchIndicator.indicator,
                                    onAppear: { await viewModel.itemAppeared(at: index) },
                                    onDisappear: { viewModel.itemDisappeared(at: index) }
                                )
                            }
                        }
                        .padding()
                    }
                }
            case let .failed(error):
                ContentUnavailableView {
                    Label("Unable to load \(title)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.loadFirstPage() }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadFirstPage() }
    }
}

private struct PlozziOSLibraryItemCell: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    let slot: LibrarySlot?
    let index: Int
    let provider: any MediaProvider
    let cardStyle: CardStyle
    let watchIndicator: WatchStatusIndicator
    let onAppear: () async -> Void
    let onDisappear: () -> Void

    var body: some View {
        Group {
            if let item = slot?.item {
                NavigationLink {
                    PlozziOSItemDetailView(
                        appModel: appModel,
                        provider: provider,
                        item: item,
                        originSourceAccountID: item.sourceAccountID
                    )
                } label: {
                    card
                }
                .buttonStyle(.plain)
            } else {
                card
            }
        }
        .task(id: index) { await onAppear() }
        .onDisappear(perform: onDisappear)
    }

    private var card: some View {
        PlozziOSPosterCard(
            item: slot?.item,
            cardStyle: cardStyle,
            watchIndicator: watchIndicator
        )
    }
}
#endif
