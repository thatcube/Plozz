#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit

/// The credits a person page can show, and how they were obtained.
///
/// Deliberately server-first. `libraryCredits` comes from the source the person
/// was seen on, using that source's own person id, so it needs no third party,
/// resolves no identities, and every entry is a title the viewer owns and can
/// play. A metadata outage costs this page its biography, not its usefulness.
@MainActor
@Observable
public final class PersonDetailViewModel {
    public enum LoadState: Equatable {
        case loading
        case loaded
        /// The source could not answer. The page still renders its header — the
        /// person's name, role and headshot all arrived with the item they were
        /// listed on, so there is always something to show.
        case unavailable
    }

    public private(set) var state: LoadState = .loading
    public private(set) var libraryCredits: [MediaItem] = []
    /// Filled only if the source keeps person records with one. Loaded alongside
    /// the credits and independently of them: a source can answer for one and not
    /// the other, and neither absence should block the other from showing.
    public private(set) var biography: String?

    private let person: MediaPerson
    private let provider: (any MediaProvider)?
    /// The viewer's *other* signed-in servers. Empty for the single-server case,
    /// which is most people — and when it is empty this class does exactly what
    /// it did before, one request, no extra latency.
    private let otherProviders: [any MediaProvider]
    /// Consulted in order, and only once every server has come back without a
    /// biography. Several rather than one so no single provider is load-bearing:
    /// drop them all and the page still shows who the person is and what the
    /// viewer owns with them.
    private let biographyProviders: [any PersonBiographyProvider]
    private let limit: Int

    public init(
        person: MediaPerson,
        provider: (any MediaProvider)?,
        otherProviders: [any MediaProvider] = [],
        biographyProviders: [any PersonBiographyProvider] = [],
        limit: Int = 40
    ) {
        self.person = person
        self.provider = provider
        self.otherProviders = otherProviders
        self.biographyProviders = biographyProviders
        self.limit = limit
    }

    /// Folds the viewer's other servers in, keyed by the person's **name** since
    /// ids do not cross servers.
    ///
    /// Additive only: anything these return is extra, and any that fail simply
    /// contribute nothing. A second server can also supply the biography the
    /// first one lacked, which is how a Plex-sourced person gets one without any
    /// third party being involved.
    private func mergeOtherServers() async {
        let name = person.name
        guard !name.isEmpty else { return }
        let limit = self.limit

        var merged = libraryCredits
        var seen = Set(merged.map(Self.dedupeKey))

        await withTaskGroup(of: (([MediaItem])?, MediaPerson?).self) { group in
            for other in otherProviders {
                group.addTask {
                    async let items = try? other.items(withPersonNamed: name, limit: limit)
                    async let record = try? other.person(named: name)
                    return (await items, await record ?? nil)
                }
            }
            for await (items, record) in group {
                if biography == nil {
                    biography = record?.biography.flatMap { $0.isEmpty ? nil : $0 }
                }
                for item in items ?? [] where seen.insert(Self.dedupeKey(item)).inserted {
                    merged.append(item)
                }
            }
        }

        libraryCredits = merged
        // A server that had nothing to say about the home source's failure should
        // not leave the page reading "unavailable" when others answered.
        if !merged.isEmpty { state = .loaded }
    }

    /// Last resort for a biography, after every server has been asked.
    ///
    /// Servers first, always: their answer is free, offline, already paid for by
    /// the library scan, and needs no name matching. Only when none of them
    /// stored one — common, since a server only keeps the bios it happened to
    /// download — is an outside source consulted, in order, stopping at the
    /// first that can confidently identify the person.
    private func fillBiographyFromExternalSources() async {
        guard biography == nil, !biographyProviders.isEmpty else { return }
        let name = person.name
        guard !name.isEmpty else { return }
        for provider in biographyProviders {
            if let text = await provider.biography(for: name, role: person.kind),
               !text.isEmpty {
                biography = text
                return
            }
        }
    }

    /// Collapses the same title held on more than one server into one entry.
    ///
    /// Title+year rather than external ids: this is a display row, the two copies
    /// are interchangeable for the viewer, and being wrong costs a duplicate
    /// poster rather than the wrong thing playing — which is why this can be
    /// looser than `RelatedTitleMatcher`, where a false match means the wrong
    /// show starts.
    private static func dedupeKey(_ item: MediaItem) -> String {
        let title = MediaItemIdentity.normalizedTitle(item.title)
        return "\(item.kind.rawValue)|\(title)|\(item.productionYear.map(String.init) ?? "")"
    }

    public func load() async {
        guard state == .loading else { return }
        guard let provider else {
            state = .unavailable
            return
        }
        // The person's own server, asked by its own exact id. Independent and
        // separately fallible from the biography: a source can list credits and
        // keep no person record, or the reverse, and neither absence should
        // suppress the other.
        async let credits = try? provider.items(withPerson: person.id, limit: limit)
        async let record = try? provider.person(id: person.id)

        // `try?` over an already-Optional return nests the optionals, so flatten
        // both once: "the call failed" and "the source had nothing" mean the same
        // thing to this page.
        let items: [MediaItem]? = await credits
        let personRecord: MediaPerson? = await record ?? nil

        biography = personRecord?.biography.flatMap { $0.isEmpty ? nil : $0 }
        if let items {
            libraryCredits = items
            state = .loaded
        } else {
            state = .unavailable
        }

        // Render what the home server gave us before consulting anyone else, so
        // time-to-content never depends on how many servers are signed in.
        if !otherProviders.isEmpty {
            await mergeOtherServers()
        }
        await fillBiographyFromExternalSources()
    }
}

/// A person's page: who they are, and what else the viewer owns with them.
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

    private static let headshotDiameter: CGFloat = 220

    public init(
        person: MediaPerson,
        viewModel: PersonDetailViewModel,
        onSelectItem: @escaping (MediaItem) -> Void
    ) {
        self.person = person
        _viewModel = State(initialValue: viewModel)
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
        .task { await viewModel.load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: PlozzTheme.Spacing.large) {
            headshot
            VStack(alignment: .leading, spacing: PlozzTheme.Spacing.small) {
                Text(person.name)
                    .font(.system(size: metrics.sectionHeaderFontSize * 1.6, weight: .bold))
                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(.system(size: metrics.sectionHeaderFontSize))
                        .plozzForeground(.secondary)
                }
                if let kind = person.kind, !kind.isEmpty, !person.isCast {
                    Text(kind)
                        .font(.system(size: metrics.sectionHeaderFontSize * 0.8))
                        .plozzForeground(.secondary)
                }
                if let biography = viewModel.biography {
                    Text(biography)
                        .font(.system(size: metrics.sectionHeaderFontSize * 0.72))
                        .plozzForeground(.secondary)
                        .lineLimit(5)
                        .padding(.top, PlozzTheme.Spacing.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
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
        .frame(width: Self.headshotDiameter, height: Self.headshotDiameter)
        .clipShape(Circle())
    }

    /// Initials on a tinted disc — the same fallback the cast rail uses, so a
    /// person with no headshot reads as "no photo" rather than a broken image.
    private var headshotPlaceholder: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.12))
            Text(initials)
                .font(.system(size: Self.headshotDiameter * 0.28, weight: .semibold))
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
        case .loaded where !viewModel.libraryCredits.isEmpty:
            // The row is focusable, so this is the one state that needs no Back
            // button of its own.
            MediaRowView(
                title: Text("Also in your library"),
                items: viewModel.libraryCredits,
                onSelect: onSelectItem
            )
        case .loading:
            creditlessState { ProgressView().scaleEffect(1.5) }
        case .loaded, .unavailable:
            // A source that couldn't answer and a person with genuinely nothing
            // else are indistinguishable here, and either way the honest thing to
            // say is that there is nothing to show.
            creditlessState {
                Text("Nothing else in your library with \(person.name).")
                    .font(.system(size: metrics.sectionHeaderFontSize))
                    .multilineTextAlignment(.center)
                    .plozzForeground(.secondary)
            }
        }
    }

    /// Any state with no credits row: the given content plus the focusable Back
    /// button that keeps Menu working.
    private func creditlessState(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: PlozzTheme.Spacing.large) {
            content()
            Button {
                dismiss()
            } label: {
                Label("Go Back", systemImage: "chevron.backward")
                    .frame(minWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .focused($backFocused)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .defaultFocus($backFocused, true)
    }
}
#endif
