#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A provider-neutral action that can share the compact overflow panel with
/// server/version choices.
public struct PlaybackSourceMenuAction: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

/// Anchored menu-shaped source selector. It uses drill-in pages rather than
/// native submenus so version rows can carry the facts needed to distinguish
/// files. iPad stays a popover; iPhone gets the system's compact adaptation.
public struct PlaybackSourceMenuButton<Label: View>: View {
    private let sources: [MediaSourceRef]
    private let selectedSourceID: String?
    private let versions: [MediaVersion]
    private let selectedVersionID: String?
    private let actions: [PlaybackSourceMenuAction]
    private let onSelectSource: (String) -> Void
    private let onSelectVersion: (String) -> Void
    private let onPerformAction: (String) -> Void
    private let label: Label

    @State private var isPresented = false
    @State private var page = PlaybackSourceMenuButtonPage.root

    public init(
        sources: [MediaSourceRef],
        selectedSourceID: String?,
        versions: [MediaVersion],
        selectedVersionID: String?,
        actions: [PlaybackSourceMenuAction] = [],
        onSelectSource: @escaping (String) -> Void,
        onSelectVersion: @escaping (String) -> Void,
        onPerformAction: @escaping (String) -> Void = { _ in },
        @ViewBuilder label: () -> Label
    ) {
        self.sources = sources
        self.selectedSourceID = selectedSourceID
        self.versions = versions
        self.selectedVersionID = selectedVersionID
        self.actions = actions
        self.onSelectSource = onSelectSource
        self.onSelectVersion = onSelectVersion
        self.onPerformAction = onPerformAction
        self.label = label()
    }

    @ViewBuilder
    public var body: some View {
        #if os(tvOS)
        trigger
            .overlay(alignment: .topTrailing) {
                if isPresented {
                    panel
                        .background {
                            Color.black.opacity(0.001)
                                .frame(width: 2_200, height: 1_300)
                                .contentShape(Rectangle())
                                .onTapGesture { isPresented = false }
                        }
                        .offset(x: -80, y: -250)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                        .zIndex(100)
                }
            }
            .zIndex(isPresented ? 100 : 0)
            .animation(.easeOut(duration: 0.16), value: isPresented)
        #else
        trigger
            .popover(
                isPresented: $isPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .trailing
            ) {
                panel
                    .presentationDetents([.medium, .large])
            }
        #endif
    }

    private var trigger: some View {
        Button {
            page = .root
            isPresented.toggle()
        } label: {
            label
        }
    }

    private var panel: some View {
        PlaybackSourceMenuPanel(
            page: $page,
            sources: sources,
            selectedSourceID: selectedSourceID,
            versions: versions.sortedForPicker(),
            selectedVersionID: selectedVersionID,
            actions: actions,
            onSelectSource: { id in
                onSelectSource(id)
                isPresented = false
            },
            onSelectVersion: { id in
                onSelectVersion(id)
                isPresented = false
            },
            onPerformAction: { id in
                onPerformAction(id)
                isPresented = false
            },
            onDismiss: { isPresented = false }
        )
        #if os(tvOS)
        .onExitCommand {
            isPresented = false
        }
        #endif
    }
}

private struct PlaybackSourceMenuPanel: View {
    @Binding var page: PlaybackSourceMenuButtonPage
    let sources: [MediaSourceRef]
    let selectedSourceID: String?
    let versions: [MediaVersion]
    let selectedVersionID: String?
    let actions: [PlaybackSourceMenuAction]
    let onSelectSource: (String) -> Void
    let onSelectVersion: (String) -> Void
    let onPerformAction: (String) -> Void
    let onDismiss: () -> Void

    @FocusState private var focusedRowID: String?
    @State private var didReceiveFocus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if page != .root {
                header
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    switch page {
                    case .root:
                        rootRows
                    case .servers:
                        serverRows
                    case .versions:
                        versionRows
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: panelWidth)
        .frame(height: panelHeight)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.32), radius: 28, y: 16)
        #if os(tvOS)
        .focusSection()
        .defaultFocus($focusedRowID, initialRowID)
        #endif
        .onAppear { focusFirstRow() }
        .onChange(of: page) { _, _ in focusFirstRow() }
        .onChange(of: focusedRowID) { _, newValue in
            if newValue != nil {
                didReceiveFocus = true
            } else if didReceiveFocus {
                onDismiss()
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            if page != .root {
                Button {
                    navigate(to: .root)
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.headline.weight(.bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            Text(pageTitle)
                .font(sectionTitleFont)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    @ViewBuilder
    private var rootRows: some View {
        if sources.count > 1 {
            drillInRow(
                id: "root.servers",
                title: "Server",
                detail: selectedSource?.displayName ?? "Choose a server",
                systemImage: "server.rack",
                destination: .servers
            )
        }
        if versions.count > 1 {
            drillInRow(
                id: "root.versions",
                title: "Version",
                detail: selectedVersion?.displayLabel ?? "Choose a version",
                systemImage: "film.stack",
                destination: .versions
            )
        }
        if !actions.isEmpty, sources.count > 1 || versions.count > 1 {
            Divider().padding(.vertical, 4)
        }
        ForEach(actions) { action in
            menuRowButton(id: "action.\(action.id)") {
                onPerformAction(action.id)
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .font(rowTitleFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var serverRows: some View {
        ForEach(sources) { source in
            menuRowButton(id: "server.\(source.accountID)") {
                onSelectSource(source.accountID)
            } label: {
                HStack(spacing: 14) {
                    if let provider = source.providerKind {
                        ProviderBrandMark(
                            provider: provider,
                            size: providerMarkSize,
                            showsBackground: false
                        )
                    } else {
                        Image(systemName: "server.rack")
                            .frame(width: providerMarkSize, height: providerMarkSize)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.displayName)
                            .font(rowTitleFont)
                        if let subtitle = sourceSubtitle(source) {
                            Text(subtitle)
                                .font(rowDetailFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    if source.accountID == selectedSourceID {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.bold))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var versionRows: some View {
        ForEach(versions) { version in
            menuRowButton(id: "version.\(version.id)") {
                onSelectVersion(version.id)
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(version.menuTitle)
                            .font(rowTitleFont)
                        if !version.menuFacts.isEmpty {
                            Text(version.menuFacts.joined(separator: " · "))
                                .font(rowDetailFont)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let fileName = version.fileName {
                            Text(fileName)
                                .font(fileNameFont)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 12)
                    if version.id == selectedVersionID {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.bold))
                    }
                }
            }
        }
    }

    private func drillInRow(
        id: String,
        title: LocalizedStringKey,
        detail: String,
        systemImage: String,
        destination: PlaybackSourceMenuButtonPage
    ) -> some View {
        menuRowButton(id: id) {
            navigate(to: destination)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .frame(width: providerMarkSize)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(rowTitleFont)
                    Text(detail)
                        .font(rowDetailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.forward")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func menuRowButton<Content: View>(
        id: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 16)
                .padding(.vertical, rowVerticalPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedRowID, equals: id)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(focusedRowID == id ? Color.primary.opacity(0.16) : Color.primary.opacity(0.055))
        )
        .scaleEffect(focusedRowID == id ? 1.018 : 1)
        .animation(.easeOut(duration: 0.12), value: focusedRowID == id)
    }

    private var selectedSource: MediaSourceRef? {
        sources.first { $0.accountID == selectedSourceID } ?? sources.first
    }

    private var selectedVersion: MediaVersion? {
        versions.first { $0.id == selectedVersionID } ?? versions.first
    }

    private func sourceSubtitle(_ source: MediaSourceRef) -> String? {
        var parts: [String] = []
        if let provider = source.providerKind?.displayName,
           provider.caseInsensitiveCompare(source.displayName) != .orderedSame {
            parts.append(provider)
        }
        if let account = source.accountName,
           account.caseInsensitiveCompare(source.displayName) != .orderedSame {
            parts.append(account)
        }
        if source.versions.count > 1 {
            parts.append("\(source.versions.count) versions")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var pageTitle: LocalizedStringKey {
        switch page {
        case .root: return "Play Options"
        case .servers: return "Server"
        case .versions: return "Version"
        }
    }

    private func focusFirstRow() {
        Task { @MainActor in
            await Task.yield()
            switch page {
            case .root:
                if sources.count > 1 { focusedRowID = "root.servers" }
                else if versions.count > 1 { focusedRowID = "root.versions" }
                else { focusedRowID = actions.first.map { "action.\($0.id)" } }
            case .servers:
                focusedRowID = sources.first.map { "server.\($0.accountID)" }
            case .versions:
                focusedRowID = versions.first.map { "version.\($0.id)" }
            }
        }
    }

    private func navigate(to destination: PlaybackSourceMenuButtonPage) {
        // The currently focused row disappears during a drill-in transition.
        // Reset this guard so that transient nil focus does not dismiss the panel
        // before the destination's default row can take focus.
        didReceiveFocus = false
        page = destination
    }

    private var initialRowID: String? {
        switch page {
        case .root:
            if sources.count > 1 { return "root.servers" }
            if versions.count > 1 { return "root.versions" }
            return actions.first.map { "action.\($0.id)" }
        case .servers:
            return sources.first.map { "server.\($0.accountID)" }
        case .versions:
            return versions.first.map { "version.\($0.id)" }
        }
    }

    private var panelWidth: CGFloat {
        #if os(tvOS)
        620
        #else
        390
        #endif
    }

    private var panelMaxHeight: CGFloat {
        #if os(tvOS)
        700
        #else
        620
        #endif
    }

    private var panelHeight: CGFloat {
        #if os(tvOS)
        switch page {
        case .root:
            let optionCount = (sources.count > 1 ? 1 : 0)
                + (versions.count > 1 ? 1 : 0)
                + actions.count
            return min(max(CGFloat(optionCount) * 104 + 32, 136), panelMaxHeight)
        case .servers:
            return min(max(CGFloat(sources.count) * 104 + 94, 250), panelMaxHeight)
        case .versions:
            return min(max(CGFloat(versions.count) * 142 + 94, 300), panelMaxHeight)
        }
        #else
        return panelMaxHeight
        #endif
    }

    private var providerMarkSize: CGFloat {
        #if os(tvOS)
        34
        #else
        24
        #endif
    }

    private var rowVerticalPadding: CGFloat {
        #if os(tvOS)
        18
        #else
        13
        #endif
    }

    private var sectionTitleFont: Font {
        #if os(tvOS)
        .title2.bold()
        #else
        .headline
        #endif
    }

    private var rowTitleFont: Font {
        #if os(tvOS)
        .system(size: 26, weight: .semibold)
        #else
        .body.weight(.semibold)
        #endif
    }

    private var rowDetailFont: Font {
        #if os(tvOS)
        .system(size: 20)
        #else
        .subheadline
        #endif
    }

    private var fileNameFont: Font {
        #if os(tvOS)
        .system(size: 17)
        #else
        .caption
        #endif
    }
}

// The generic button's nested type cannot be named in a non-generic panel.
private enum PlaybackSourceMenuButtonPage: Hashable {
    case root
    case servers
    case versions
}

#endif
