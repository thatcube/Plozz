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
    private let onDismiss: () -> Void
    private let label: Label

    @State private var isPresented = false
    @State private var page = PlaybackSourceMenuButtonPage.root
    @State private var triggerFrame: CGRect = .zero

    public init(
        sources: [MediaSourceRef],
        selectedSourceID: String?,
        versions: [MediaVersion],
        selectedVersionID: String?,
        actions: [PlaybackSourceMenuAction] = [],
        onSelectSource: @escaping (String) -> Void,
        onSelectVersion: @escaping (String) -> Void,
        onPerformAction: @escaping (String) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {},
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
        self.onDismiss = onDismiss
        self.label = label()
    }

    @ViewBuilder
    public var body: some View {
        #if os(tvOS)
        trigger
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                triggerFrame = frame
            }
            .fullScreenCover(isPresented: $isPresented, onDismiss: onDismiss) {
                tvOSPresentation
            }
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

    #if os(tvOS)
    private var tvOSPresentation: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }

            panel
                .offset(
                    x: triggerFrame.minX,
                    y: triggerFrame.minY - panelHeight - 12
                )
        }
        .ignoresSafeArea()
        .presentationBackground(.clear)
    }
    #endif

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
            }
        )
        #if os(tvOS)
        .onExitCommand {
            handleExit()
        }
        #endif
    }

    private var panelHeight: CGFloat {
        PlaybackSourceMenuMetrics.panelHeight(
            page: page,
            sourceCount: sources.count,
            versionCount: versions.count,
            actionCount: actions.count
        )
    }

    private func handleExit() {
        if page != .root {
            withAnimation(.easeInOut(duration: 0.28)) {
                page = .root
            }
        } else {
            isPresented = false
        }
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

    @Namespace private var panelFocusScope
    #if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
    #endif
    @FocusState private var focusedRowID: String?
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
                .padding(14)
            }
            .scrollIndicators(.hidden)
        }
        // Page content swaps immediately; only the glass container morphs.
        .animation(nil, value: page)
        .frame(width: panelWidth)
        .frame(height: panelHeight, alignment: .top)
        .plozzGlassPanel(cornerRadius: 32, scrimOpacity: 0.08)
        #if os(tvOS)
        .focusScope(panelFocusScope)
        .focusSection()
        .defaultFocus($focusedRowID, initialRowID)
        #endif
        .onAppear { focusFirstRow() }
        .onChange(of: page) { _, _ in focusFirstRow() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            if page != .root {
                Button {
                    navigate(to: .root)
                } label: {
                    Image(systemName: "chevron.backward")
                        .accessibilityLabel("Back")
                }
                .buttonStyle(PlozzPanelHeaderButtonStyle())
                .focusEffectDisabled()
                .focused($focusedRowID, equals: "header.back")
            }
            Text(page == .servers ? "Servers" : "Versions")
                .font(.headline.weight(.semibold))
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
                                .settingsRowSecondary()
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
            let title = version.displayLabel
            let titleFacts = Set(title.components(separatedBy: " · "))
            let supplementalFacts = version.menuFacts.filter { !titleFacts.contains($0) }
            menuRowButton(id: "version.\(version.id)") {
                onSelectVersion(version.id)
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(rowTitleFont)
                        if !supplementalFacts.isEmpty {
                            Text(supplementalFacts.joined(separator: " · "))
                                .font(rowDetailFont)
                                .settingsRowSecondary()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let fileName = version.fileName {
                            Text(fileName)
                                .font(fileNameFont)
                                .settingsRowSecondary()
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
        menuRowButton(id: id, fixedHeight: rootRowHeight) {
            navigate(to: destination)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .frame(width: providerMarkSize)
                    .settingsRowIcon()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                       .font(rowCategoryFont)
                       .textCase(.uppercase)
                       .tracking(0.8)
                       .settingsRowSecondary()
                    Text(detail)
                       .font(rowTitleFont)
                       .lineLimit(2)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.forward")
                    .settingsRowSecondary()
            }
        }
    }

    private func menuRowButton<Content: View>(
        id: String,
        fixedHeight: CGFloat? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 16)
                .modifier(
                    PlaybackSourceMenuRowHeight(
                       fixedHeight: fixedHeight,
                       verticalPadding: rowVerticalPadding
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        .focused($focusedRowID, equals: id)
        #if os(tvOS)
        .prefersDefaultFocus(id == initialRowID, in: panelFocusScope)
        #endif
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
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

    private func focusFirstRow() {
        let target = initialRowID
        focusedRowID = target
        #if os(tvOS)
        resetFocus(in: panelFocusScope)
        #endif
    }

    private func navigate(to destination: PlaybackSourceMenuButtonPage) {
        withAnimation(.easeInOut(duration: 0.28)) {
            page = destination
        }
    }

    private var initialRowID: String? {
        switch page {
        case .root:
            if sources.count > 1 { return "root.servers" }
            if versions.count > 1 { return "root.versions" }
            return actions.first.map { "action.\($0.id)" }
        case .servers:
            let source = sources.first { $0.accountID == selectedSourceID } ?? sources.first
            return source.map { "server.\($0.accountID)" }
        case .versions:
            let version = versions.first { $0.id == selectedVersionID } ?? versions.first
            return version.map { "version.\($0.id)" }
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
        PlaybackSourceMenuMetrics.panelHeight(
            page: page,
            sourceCount: sources.count,
            versionCount: versions.count,
            actionCount: actions.count
        )
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

    private var rootRowHeight: CGFloat? {
        #if os(tvOS)
        82
        #else
        nil
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

    private var rowCategoryFont: Font {
        #if os(tvOS)
        .system(size: 14, weight: .semibold)
        #else
        .caption2.weight(.semibold)
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

private struct PlaybackSourceMenuRowHeight: ViewModifier {
    let fixedHeight: CGFloat?
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        if let fixedHeight {
            content.frame(height: fixedHeight)
        } else {
            content.padding(.vertical, verticalPadding)
        }
    }
}

// The generic button's nested type cannot be named in a non-generic panel.
private enum PlaybackSourceMenuButtonPage: Hashable {
    case root
    case servers
    case versions
}

private enum PlaybackSourceMenuMetrics {
    static func panelHeight(
        page: PlaybackSourceMenuButtonPage,
        sourceCount: Int,
        versionCount: Int,
        actionCount: Int
    ) -> CGFloat {
        #if os(tvOS)
        switch page {
        case .root:
            let optionCount = (sourceCount > 1 ? 1 : 0) + (versionCount > 1 ? 1 : 0)
            let rowCount = optionCount + actionCount
            let rowSpacing = CGFloat(max(rowCount - 1, 0)) * 8
            let dividerHeight: CGFloat = optionCount > 0 && actionCount > 0 ? 17 : 0
            let contentHeight = CGFloat(optionCount) * 82
                + CGFloat(actionCount) * 67
                + rowSpacing
                + dividerHeight
            return min(max(contentHeight + 28, 110), 700)
        case .servers:
            return min(max(CGFloat(sourceCount) * 104 + 94, 250), 700)
        case .versions:
            return min(max(CGFloat(versionCount) * 142 + 94, 300), 700)
        }
        #else
        return 620
        #endif
    }
}

#endif
