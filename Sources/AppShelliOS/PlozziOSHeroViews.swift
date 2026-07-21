#if os(iOS)
import AVFoundation
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import HeroUI
import MediaDownloads
import Observation
import SwiftUI
import UIKit

enum PlozziOSHeroMetrics {
    static func height(
        style: HeroArtworkStyle,
        surfaceRole: HeroTrailerSurfaceRole,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        let base: CGFloat
        if style == .compactPortrait {
            base = 610
        } else {
            base = surfaceRole == .detail ? 760 : 680
        }
        guard dynamicTypeSize.isAccessibilitySize else { return base }
        return base + (style == .compactPortrait ? 160 : 140)
    }

}

enum PlozziOSPageLayout {
    static func horizontalInset(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .compact ? 22 : 36
    }

    static func horizontalInset(for style: HeroArtworkStyle) -> CGFloat {
        style == .compactPortrait ? 22 : 36
    }

    static func heroTextMaxWidth(for style: HeroArtworkStyle) -> CGFloat {
        style == .compactPortrait ? 500 : 480
    }

    static func heroStageMaxWidth(
        for style: HeroArtworkStyle,
        surfaceRole: HeroTrailerSurfaceRole
    ) -> CGFloat {
        guard style == .landscape else { return 560 }
        return surfaceRole == .detail
            ? .infinity
            : heroTextMaxWidth(for: style)
    }
}

@MainActor
@Observable
final class PlozziOSSidebarGeometryModel {
    private(set) var coveredWidth: CGFloat = 0
    private(set) var isVisible = false

    func recordCoveredWidth(_ width: CGFloat) {
        guard width > 1, coveredWidth != width else { return }
        coveredWidth = width
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
    }
}

struct PlozziOSHomeHeroSlide: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(HeroTrailerController.self) private var trailerController
    @Environment(PlozziOSAppModel.self) private var appModel

    let item: MediaItem
    let isSelected: Bool

    var body: some View {
        let style: HeroArtworkStyle = horizontalSizeClass == .compact
            ? .compactPortrait
            : .landscape
        let presentation = HeroPresentation(
            item: item,
            artworkStyle: style,
            surface: .home
        )
        PlozziOSHeroStage(
            item: item,
            presentation: presentation,
            style: style,
            surfaceRole: .home,
            isActive: isSelected,
            showsBackdrop: false,
            showsScrim: false,
            showsMuteButton: false,
            trailerController: trailerController,
            backgroundSettings: appModel.settings.heroBackground,
            trailerResolver: appModel.heroTrailerResolver()
        ) {
            EmptyView()
        }
    }
}

struct PlozziOSDetailHeroSection: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(HeroTrailerController.self) private var trailerController
    @Environment(PlozziOSAppModel.self) private var appModel

    let item: MediaItem
    let backdropItem: MediaItem
    let playableItem: MediaItem?
    let downloadItem: MediaItem?
    let sources: [MediaSourceRef]
    let selectedSourceAccountID: String?
    let versions: [MediaVersion]
    let selectedVersionID: String?
    let onSelectSource: (String) -> Void
    let onSelectVersion: (String) -> Void
    let actionHandler: any MediaItemActionHandling
    let onPlay: (MediaItem, Bool) -> Void

    var body: some View {
        let style: HeroArtworkStyle = horizontalSizeClass == .compact
            ? .compactPortrait
            : .landscape
        let presentation = HeroPresentation(
            item: item,
            artworkStyle: style,
            surface: .detail
        )
        let backdropPresentation = HeroPresentation(
            item: backdropItem,
            artworkStyle: style,
            surface: .detail
        )
        PlozziOSHeroStage(
            item: backdropItem,
            presentation: backdropPresentation,
            style: style,
            surfaceRole: .detail,
            isActive: true,
            trailerController: trailerController,
            backgroundSettings: appModel.settings.heroBackground,
            trailerResolver: appModel.heroTrailerResolver()
        ) {
            PlozziOSDetailHeroForeground(
                item: item,
                rootItem: backdropItem,
                playableItem: playableItem,
                downloadItem: downloadItem,
                sources: sources,
                selectedSourceAccountID: selectedSourceAccountID,
                versions: versions,
                selectedVersionID: selectedVersionID,
                onSelectSource: onSelectSource,
                onSelectVersion: onSelectVersion,
                presentation: presentation,
                fallbackPresentation: backdropPresentation,
                style: style,
                actionHandler: actionHandler,
                onPlay: onPlay
            )
        }
    }
}

private struct PlozziOSHeroStage<Foreground: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: MediaItem
    let presentation: HeroPresentation
    let style: HeroArtworkStyle
    let surfaceRole: HeroTrailerSurfaceRole
    let isActive: Bool
    var showsBackdrop = true
    var showsScrim = true
    var showsMuteButton = true
    let trailerController: HeroTrailerController
    let backgroundSettings: HeroBackgroundSettingsModel
    let trailerResolver: HeroTrailerResolving
    @ViewBuilder let foreground: () -> Foreground

    private var height: CGFloat {
        PlozziOSHeroMetrics.height(
            style: style,
            surfaceRole: surfaceRole,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    var body: some View {
        ZStack {
            if showsBackdrop {
                PlozziOSReflectedHeroStage(height: height) { _ in
                    PlozziOSHeroBackdrop(
                        presentation: presentation,
                        style: style,
                        itemID: item.id,
                        height: height,
                        showsScrim: showsScrim,
                        ignoresHorizontalSafeArea: false,
                        surfaceRole: surfaceRole,
                        trailerController: trailerController
                    )
                } reflection: { reflectionWidth, contentWidth in
                    PlozziOSHeroReflection(
                        presentation: presentation,
                        itemID: item.id,
                        width: reflectionWidth,
                        contentWidth: contentWidth,
                        height: height,
                        trailerController: trailerController
                    )
                }
            } else {
                Color.clear
            }

            foreground()
                .frame(
                    maxWidth: PlozziOSPageLayout.heroStageMaxWidth(
                        for: style,
                        surfaceRole: surfaceRole
                    )
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: style == .compactPortrait
                        ? .bottom
                        : .bottomLeading
                )
                .padding(
                    .horizontal,
                    PlozziOSPageLayout.horizontalInset(for: style)
                )
                .padding(.bottom, style == .compactPortrait ? 30 : 42)

            if showsMuteButton,
               backgroundSettings.settings.mode == .trailer,
               trailerController.currentItemID == item.id,
               trailerController.isPlaying {
                PlozziOSHeroMuteButton(
                    isMuted: backgroundSettings.settings.trailerMuted,
                    onToggle: toggleMuted
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topTrailing
                )
                .padding(.top, 18)
                .padding(.trailing, 18)
            }
        }
        .frame(height: height)
        .task(
            id: PlozziOSHeroPlaybackID(
                itemID: item.id,
                isActive: isActive,
                mode: backgroundSettings.settings.mode,
                role: surfaceRole
            )
        ) {
            await updateTrailerPlayback()
        }
        .onChange(
            of: backgroundSettings.settings.trailerMuted,
            initial: true
        ) { _, muted in
            if trailerController.isShowing(item.id) {
                trailerController.setMuted(muted)
            }
        }
        .onDisappear(perform: releaseTrailerSurface)
    }

    private func updateTrailerPlayback() async {
        guard isActive, backgroundSettings.settings.trailerAutoplayEnabled else {
            trailerController.stop(ifShowing: item.id)
            return
        }
        if !trailerController.isShowing(item.id) {
            trailerController.stop()
        }
        trailerController.claimSurface(surfaceRole, itemID: item.id)
        if surfaceRole == .detail {
            trailerController.setEndHandler(
                ownerID: detailEndHandlerOwnerID,
                {}
            )
        }
        if trailerController.isShowing(item.id) {
            trailerController.setMuted(backgroundSettings.settings.trailerMuted)
            if !trailerController.isPlaying {
                await startPreparedAfterLeadIn()
            }
            return
        }
        guard let source = await trailerResolver(item),
              !Task.isCancelled else {
            return
        }
        trailerController.prepare(
            itemID: item.id,
            resolvedURL: source.url,
            muted: backgroundSettings.settings.trailerMuted
        )
        trailerController.claimSurface(surfaceRole, itemID: item.id)
        while !trailerController.isReady {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isActive,
                  trailerController.isShowing(item.id) else {
                return
            }
        }
        await startPreparedAfterLeadIn()
    }

    private func startPreparedAfterLeadIn() async {
        do {
            try await Task.sleep(
                for: .seconds(HeroTrailerTimeline.leadIn)
            )
        } catch {
            return
        }
        guard !Task.isCancelled,
              isActive,
              trailerController.isShowing(item.id) else {
            return
        }
        trailerController.startPrepared()
    }

    private func toggleMuted() {
        backgroundSettings.settings.trailerMuted.toggle()
        trailerController.setMuted(backgroundSettings.settings.trailerMuted)
    }

    private func releaseTrailerSurface() {
        if surfaceRole == .detail {
            trailerController.clearEndHandler(ownerID: detailEndHandlerOwnerID)
            trailerController.releaseSurface(.detail)
            trailerController.stop(ifShowing: item.id)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if trailerController.isClaimed(by: .home, itemID: item.id) {
                trailerController.releaseSurface(.home)
                trailerController.stop(ifShowing: item.id)
            }
        }
    }

    private var detailEndHandlerOwnerID: String {
        "ios-detail-\(item.id)"
    }

}

private struct PlozziOSHeroPlaybackID: Equatable {
    let itemID: String
    let isActive: Bool
    let mode: HeroBackgroundMode
    let role: HeroTrailerSurfaceRole
}

private struct PlozziOSHeroBackdrop: View {
    @Environment(\.themePalette) private var palette

    let presentation: HeroPresentation
    let style: HeroArtworkStyle
    let itemID: String
    let height: CGFloat
    let showsScrim: Bool
    let ignoresHorizontalSafeArea: Bool
    let surfaceRole: HeroTrailerSurfaceRole
    let trailerController: HeroTrailerController

    var body: some View {
        ZStack {
            FallbackAsyncImage(
                references: presentation.artworkReferences,
                variant: .heroBackdrop
            ) {
                palette.backgroundBase
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if trailerController.currentItemID == itemID,
               trailerController.isPlaying {
                HeroTrailerVideoLayer(
                    controller: trailerController,
                    role: surfaceRole
                )
                .transition(.opacity)
            }

            if showsScrim {
                PlozziOSHeroScrim(style: style)
            }
        }
        .frame(height: height)
        // Fade the complete artwork/video stack to transparent rather than
        // painting an approximate background color over its bottom edge. The
        // actual themed page background then shows through with no visible seam.
        .mask { PlozziOSHeroFadeMask() }
        .clipped()
        .ignoresSafeArea(
            edges: ignoresHorizontalSafeArea
                ? [.top, .horizontal]
                : .top
        )
    }
}

struct PlozziOSHeroScrim: View {
    @Environment(\.colorScheme) private var colorScheme

    let style: HeroArtworkStyle

    private var tone: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.25),
                    .init(color: tone.opacity(0.14), location: 0.48),
                    .init(color: tone.opacity(0.58), location: 0.76),
                    .init(color: tone.opacity(0.82), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            if style == .landscape {
                LinearGradient(
                    colors: [tone.opacity(0.62), .clear],
                    startPoint: .leading,
                    endPoint: .center
                )
            }
        }
    }
}

private struct PlozziOSHeroFadeMask: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.76),
                .init(color: .black.opacity(0.72), location: 0.88),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct PlozziOSStationaryHeroScrim: View {
    let style: HeroArtworkStyle
    let height: CGFloat

    var body: some View {
        PlozziOSFullWidthHeroStage(height: height) {
            PlozziOSHeroScrim(style: style)
                .mask { PlozziOSHeroFadeMask() }
                .frame(height: height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PlozziOSHomeWipeBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(HeroTrailerController.self) private var trailerController

    let item: MediaItem
    let style: HeroArtworkStyle
    let height: CGFloat
    let forward: Bool

    var body: some View {
        let presentation = HeroPresentation(
            item: item,
            artworkStyle: style,
            surface: .home
        )
        PlozziOSReflectedHeroStage(height: height) { usableWidth in
            backdrop(
                presentation: presentation,
                width: usableWidth
            )
        } reflection: { reflectionWidth, contentWidth in
            PlozziOSHeroReflection(
                presentation: presentation,
                itemID: item.id,
                width: reflectionWidth,
                contentWidth: contentWidth,
                height: height,
                trailerController: trailerController
            )
        }

    }

    private func backdrop(
        presentation: HeroPresentation,
        width: CGFloat
    ) -> some View {
        HomeHeroBackdrop(
            references: presentation.artworkReferences,
            asyncFallbackURL: nil,
            slideID: item.id,
            forward: forward,
            width: width,
            height: height,
            scrimTone: colorScheme == .dark ? .black : .white,
            trailerController: trailerController,
            showsTrailer: trailerController.isShowing(item.id)
                && trailerController.isPlaying,
            ignoresHorizontalSafeArea: false,
            scrimOpacity: 0
        )
    }

}

struct PlozziOSHomeStaticBackdrop: View {
    @Environment(HeroTrailerController.self) private var trailerController

    let item: MediaItem
    let style: HeroArtworkStyle
    let height: CGFloat

    var body: some View {
        let presentation = HeroPresentation(
            item: item,
            artworkStyle: style,
            surface: .home
        )
        PlozziOSReflectedHeroStage(height: height) { _ in
            PlozziOSHeroBackdrop(
                presentation: presentation,
                style: style,
                itemID: item.id,
                height: height,
                showsScrim: false,
                ignoresHorizontalSafeArea: false,
                surfaceRole: .home,
                trailerController: trailerController
            )
        } reflection: { reflectionWidth, contentWidth in
            PlozziOSHeroReflection(
                presentation: presentation,
                itemID: item.id,
                width: reflectionWidth,
                contentWidth: contentWidth,
                height: height,
                trailerController: trailerController
            )
        }
    }
}

private struct PlozziOSHeroReflection: View {
    @Environment(\.colorScheme) private var colorScheme

    let presentation: HeroPresentation
    let itemID: String
    let width: CGFloat
    let contentWidth: CGFloat
    let height: CGFloat
    let trailerController: HeroTrailerController

    var body: some View {
        ZStack {
            FallbackAsyncImage(
                references: presentation.artworkReferences,
                variant: .heroBackdrop
            ) {
                Color.clear
            }
            .frame(width: contentWidth, height: height)

            if trailerController.isShowing(itemID),
               trailerController.isPlaying {
                PlozziOSMirrorVideoLayer(
                    player: trailerController.player
                )
                .frame(width: contentWidth, height: height)
            }

            (colorScheme == .dark ? Color.black : Color.white)
                .opacity(0.22)
        }
        .frame(width: contentWidth, height: height)
        .frame(width: width, alignment: .leading)
        .clipped()
        .scaleEffect(x: -1)
        .blur(radius: 28, opaque: true)
        .mask { PlozziOSHeroFadeMask() }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PlozziOSMirrorVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }
}

struct PlozziOSHomeHeroForeground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(PlozziOSAppModel.self) private var appModel
    @Environment(\.mediaItemActionHandler) private var actionHandler

    let item: MediaItem
    let detailItem: MediaItem
    let watchlistItem: MediaItem
    let presentation: HeroPresentation
    let style: HeroArtworkStyle
    let provider: (any MediaProvider)?
    let onPlay: (MediaItem) -> Void

    var body: some View {
        VStack(
            alignment: style == .compactPortrait ? .center : .leading,
            spacing: 12
        ) {
            PlozziOSHeroMetadata(
                presentation: presentation,
                style: style,
                mode: .home,
                hidesRatings: appModel.settings.spoilers.settings
                    .shouldHideRatings(for: item)
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actionButtons }
                VStack(spacing: 12) { actionButtons }
            }
            .controlSize(.large)
        }
        .frame(
            maxWidth: .infinity,
            alignment: style == .compactPortrait ? .center : .leading
        )
        .multilineTextAlignment(style == .compactPortrait ? .center : .leading)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if hasPlayAction {
            Button {
                onPlay(item)
            } label: {
                PlayResumeButtonLabel(
                    title: "Play",
                    progress: item.resumeProgressFraction,
                    remainingText: item.resumeRemainingText,
                    seasonEpisodeText: seasonEpisodeText,
                    onLight: colorScheme == .dark,
                    spacing: 10,
                    capsuleWidth: 60
                )
            }
            .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary))
        }

        if let watchlistAction {
            Button {
                actionHandler?.perform(
                    watchlistAction,
                    on: watchlistItem,
                    context: .none
                )
            } label: {
                Image(
                    systemName: watchlistItem.isFavorite
                        ? "bookmark.fill"
                        : "bookmark"
                )
                .font(.headline.weight(.semibold))
            }
            .buttonStyle(
                PlozziOSHeroActionButtonStyle(
                    kind: .secondary,
                    circular: true
                )
            )
            .accessibilityLabel(watchlistAction.title)
        }

        if let provider {
            NavigationLink {
                PlozziOSItemDetailView(
                    appModel: appModel,
                    provider: provider,
                    item: detailItem,
                    seerService: appModel.seerService
                )
            } label: {
                if hasPlayAction {
                    Image(systemName: "info.circle")
                        .font(.headline.weight(.semibold))
                } else {
                    Label("More Info", systemImage: "info.circle")
                }
            }
            .buttonStyle(
                PlozziOSHeroActionButtonStyle(
                    kind: hasPlayAction ? .secondary : .primary,
                    circular: hasPlayAction
                )
            )
            .accessibilityLabel("More Info")
        }
    }

    private var hasPlayAction: Bool {
        !item.isNotInLibraryDiscovery
            && (item.kind == .movie
                || item.kind == .episode
                || item.kind == .video)
    }

    private var seasonEpisodeText: String? {
        guard item.kind == .episode,
              let season = item.seasonNumber,
              let episode = item.episodeNumber else {
            return nil
        }
        return "S\(season), E\(episode)"
    }

    private var watchlistAction: MediaItemAction? {
        actionHandler?.actions(for: watchlistItem, context: .none)
            .first {
                $0 == .addToWatchlist || $0 == .removeFromWatchlist
            }
    }
}

private struct PlozziOSDetailHeroForeground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var downloadRecord: DownloadedMediaRecord?
    @State private var downloadError: String?

    let item: MediaItem
    let rootItem: MediaItem
    let playableItem: MediaItem?
    let downloadItem: MediaItem?
    let sources: [MediaSourceRef]
    let selectedSourceAccountID: String?
    let versions: [MediaVersion]
    let selectedVersionID: String?
    let onSelectSource: (String) -> Void
    let onSelectVersion: (String) -> Void
    let presentation: HeroPresentation
    let fallbackPresentation: HeroPresentation
    let style: HeroArtworkStyle
    let actionHandler: any MediaItemActionHandling
    let onPlay: (MediaItem, Bool) -> Void

    private struct ActionEntry: Identifiable {
        let action: MediaItemAction
        let target: MediaItem
        var id: MediaItemAction { action }
    }

    private var actions: [ActionEntry] {
        var seen = Set<MediaItemAction>()
        var entries: [ActionEntry] = []
        for target in [item, rootItem] {
            for action in actionHandler.actions(for: target, context: .none)
                where !action.isNavigation && seen.insert(action).inserted {
                entries.append(ActionEntry(action: action, target: target))
            }
        }
        return entries
    }

    private var primaryActions: [ActionEntry] {
        actions.filter(\.action.isPrimaryDetailAction)
    }

    private var contextActions: [ActionEntry] {
        actions.filter { !$0.action.isPrimaryDetailAction }
    }

    var body: some View {
        VStack(
            alignment: style == .compactPortrait ? .center : .leading,
            spacing: 12
        ) {
            PlozziOSHeroMetadata(
                presentation: presentation,
                style: style,
                mode: .detail,
                fallbackPresentation: fallbackPresentation,
                technicalBadgesOverride: playableItem?.technicalBadges,
                hidesRatings: appModel.settings.spoilers.settings
                    .shouldHideRatings(for: item)
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actionButtons }
                VStack(spacing: 12) { actionButtons }
            }
            .controlSize(.large)
        }
        .frame(
            maxWidth: PlozziOSPageLayout.heroTextMaxWidth(for: style),
            alignment: style == .compactPortrait ? .center : .leading
        )
        .frame(
            maxWidth: .infinity,
            alignment: style == .compactPortrait ? .center : .leading
        )
        .overlay(alignment: .bottomTrailing) {
            if style == .landscape {
                PlozziOSDetailCredits(
                    focused: presentation,
                    root: fallbackPresentation
                )
                .frame(width: 280, alignment: .trailing)
            }
        }
        .multilineTextAlignment(style == .compactPortrait ? .center : .leading)
        .contextMenu {
            detailContextMenu
        }
        .task(id: downloadItem?.id) {
            guard let downloadItem else {
                downloadRecord = nil
                return
            }
            downloadRecord = await appModel.downloads.record(for: downloadItem)
        }
        .alert(
            "Download Failed",
            isPresented: Binding(
                get: { downloadError != nil },
                set: { if !$0 { downloadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let playableItem {
            Button {
                onPlay(playableItem, false)
            } label: {
                PlayResumeButtonLabel(
                    title: "Play",
                    progress: playableItem.resumeProgressFraction,
                    remainingText: playableItem.resumeRemainingText,
                    seasonEpisodeText: seasonEpisodeText(for: playableItem),
                    onLight: colorScheme == .dark,
                    spacing: 10,
                    capsuleWidth: 60
                )
            }
            .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary))

        }

        ForEach(primaryActions) { entry in
            Button {
                actionHandler.perform(
                    entry.action,
                    on: entry.target,
                    context: .none
                )
            } label: {
                Image(systemName: primaryActionSymbol(for: entry))
                    .font(.headline)
            }
            .buttonStyle(
                PlozziOSHeroActionButtonStyle(
                    kind: .secondary,
                    circular: true
                )
            )
            .accessibilityLabel(entry.action.title)
        }
        if downloadItem != nil {
            downloadMenuAction
                .buttonStyle(
                    PlozziOSHeroActionButtonStyle(
                        kind: .secondary,
                        circular: true
                    )
                )
        }
    }

    private func primaryActionSymbol(for entry: ActionEntry) -> String {
        switch entry.action {
        case .markWatched:
            return "eye"
        case .markUnwatched:
            return "checkmark.circle.fill"
        case .addToWatchlist:
            return "bookmark"
        case .removeFromWatchlist:
            return "bookmark.fill"
        default:
            return entry.action.systemImage
        }
    }

    @ViewBuilder
    private var detailContextMenu: some View {
        ForEach(contextActions) { entry in
            Button(
                entry.action.title,
                systemImage: entry.action.systemImage
            ) {
                actionHandler.perform(
                    entry.action,
                    on: entry.target,
                    context: .none
                )
            }
        }
        if sources.count > 1 {
            Menu(selectedSourceLabel, systemImage: "server.rack") {
                ForEach(sources) { source in
                    Button {
                        onSelectSource(source.accountID)
                    } label: {
                        if source.accountID == selectedSourceAccountID {
                            Label(source.displayName, systemImage: "checkmark")
                        } else {
                            Text(source.displayName)
                        }
                    }
                }
            }
        }
        if versions.count > 1 {
            Menu(selectedVersionLabel, systemImage: "film.stack") {
                ForEach(versions) { version in
                    Button {
                        onSelectVersion(version.id)
                    } label: {
                        if version.id == selectedVersionID {
                            Label(version.displayLabel, systemImage: "checkmark")
                        } else {
                            Text(version.displayLabel)
                        }
                    }
                }
            }
        }
    }

    private var selectedSourceLabel: String {
        sources.first { $0.accountID == selectedSourceAccountID }?
            .displayName
            ?? sources.first?.displayName
            ?? "Server"
    }

    private var selectedVersionLabel: String {
        versions.first { $0.id == selectedVersionID }?
            .displayLabel
            ?? versions.first?.displayLabel
            ?? "Play Version"
    }

    private func seasonEpisodeText(for item: MediaItem) -> String? {
        guard item.kind == .episode,
              let season = item.seasonNumber,
              let episode = item.episodeNumber else {
            return nil
        }
        return "S\(season), E\(episode)"
    }

    @ViewBuilder
    private var downloadMenuAction: some View {
        Button {
            Task { await performDownloadAction() }
        } label: {
            Image(systemName: downloadActionSymbol)
                .font(.headline)
        }
        .accessibilityLabel(downloadActionTitle)
    }

    private var downloadActionTitle: String {
        switch currentDownloadRecord?.status {
        case .queued, .downloading:
            return "Pause Download"
        case .paused, .failed:
            return "Resume Download"
        case .completed:
            return "Remove Download"
        case nil:
            return "Download"
        }
    }

    private var downloadActionSymbol: String {
        switch currentDownloadRecord?.status {
        case .queued, .downloading:
            return "pause.circle"
        case .paused, .failed:
            return "arrow.clockwise.circle"
        case .completed:
            return "trash"
        case nil:
            return "arrow.down.circle"
        }
    }

    private func performDownloadAction() async {
        switch currentDownloadRecord?.status {
        case .queued, .downloading:
            await pauseDownload()
        case .paused, .failed:
            await resumeDownload()
        case .completed:
            await removeDownload()
        case nil:
            await startDownload()
        }
    }

    private var currentDownloadRecord: DownloadedMediaRecord? {
        guard let downloadRecord else { return nil }
        return appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        } ?? downloadRecord
    }

    private func startDownload() async {
        guard let downloadItem else { return }
        do {
            guard let provider = appModel.provider(for: downloadItem) else {
                downloadError = "The selected server is no longer available."
                return
            }
            downloadRecord = try await appModel.downloads.enqueue(
                item: downloadItem,
                provider: provider
            )
        } catch {
            downloadError = error.localizedDescription
        }
    }

    private func pauseDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.pause(record)
        downloadRecord = appModel.downloads.records.first {
            $0.identityKey == record.identityKey
        }
    }

    private func resumeDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.resume(record)
        downloadRecord = appModel.downloads.records.first {
            $0.identityKey == record.identityKey
        }
    }

    private func removeDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.remove(record)
        downloadRecord = nil
    }
}

private struct PlozziOSHeroActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind
    var circular = false
    @Environment(\.themePalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        styledLabel(configuration)
            .contentShape(circular ? AnyShape(Circle()) : AnyShape(Capsule()))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private func styledLabel(_ configuration: Configuration) -> some View {
        if circular {
            configuration.label
                .foregroundStyle(
                    kind == .primary
                        ? palette.backgroundBase
                        : palette.primaryText
                )
                .frame(width: 48, height: 48)
                .background {
                    Circle()
                        .fill(backgroundColor)
                        .overlay {
                            if kind == .secondary {
                                Circle()
                                    .strokeBorder(
                                        palette.primaryText.opacity(0.2),
                                        lineWidth: 1
                                    )
                            }
                        }
                }
        } else {
            configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(
                kind == .primary
                    ? palette.backgroundBase
                    : palette.primaryText
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .background {
                Capsule()
                    .fill(
                        kind == .primary
                            ? palette.primaryText
                            : palette.cardSurface.opacity(0.92)
                    )
                    .overlay {
                        if kind == .secondary {
                            Capsule()
                                .strokeBorder(
                                    palette.primaryText.opacity(0.2),
                                    lineWidth: 1
                                )
                        }
                    }
            }
            .contentShape(Capsule())
        }
    }

    private var backgroundColor: Color {
        kind == .primary
            ? palette.primaryText
            : palette.cardSurface.opacity(0.92)
    }
}

private struct PlozziOSHeroMetadata: View {
    enum Mode {
        case home
        case detail
    }

    @Environment(\.themePalette) private var palette
    let presentation: HeroPresentation
    let style: HeroArtworkStyle
    let mode: Mode
    var fallbackPresentation: HeroPresentation? = nil
    var technicalBadgesOverride: [MediaBadge]? = nil
    var hidesRatings = false

    var body: some View {
        VStack(
            alignment: style == .compactPortrait ? .center : .leading,
            spacing: 9
        ) {
            HeroLogoArtwork(
                references: presentation.logoReferences,
                maxWidth: style == .compactPortrait ? 330 : 520,
                maxHeight: style == .compactPortrait ? 95 : 130,
                alignment: style == .compactPortrait ? .center : .leading
            ) {
                Text(presentation.title)
                    .font(style == .compactPortrait ? .largeTitle : .largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)
            }
            .accessibilityLabel(Text(presentation.title))
            .accessibilityAddTraits(.isHeader)

            if effectiveRatingBadge != nil || !effectiveGenres.isEmpty {
                HStack(spacing: 10) {
                    if let badge = effectiveRatingBadge {
                        MediaBadgeChip(badge: badge)
                    }
                    if !effectiveGenres.isEmpty {
                        Text(effectiveGenres.joined(separator: "  ·  "))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(palette.primaryText.opacity(0.92))
            }

            if let descriptionText {
                Text(descriptionText)
                    .font(.subheadline)
                    .foregroundStyle(palette.primaryText.opacity(0.82))
                    .lineLimit(3)
                    .frame(
                        maxWidth: PlozziOSPageLayout.heroTextMaxWidth(
                            for: style
                        ),
                        alignment: style == .compactPortrait
                            ? .center
                            : .leading
                    )
                    .multilineTextAlignment(
                        style == .compactPortrait ? .center : .leading
                    )
            }

            if mode == .home, !effectiveRatings.isEmpty {
                RatingsBadgeRow(
                    ratings: effectiveRatings
                )
                .frame(
                    maxWidth: .infinity,
                    alignment: style == .compactPortrait
                        ? .center
                        : .leading
                )
            } else if mode == .detail,
                      !factComponents.isEmpty
                        || !effectiveRatings.isEmpty
                        || !effectiveTechnicalBadges.isEmpty {
                WrappingHStackLayout(
                    alignment: style == .compactPortrait ? .center : .leading,
                    spacing: 12,
                    lineSpacing: 8
                ) {
                    if !factComponents.isEmpty {
                        Text(factComponents.joined(separator: "  ·  "))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    ForEach(effectiveRatings) { rating in
                        RatingBadge(rating: rating)
                    }
                    ForEach(effectiveTechnicalBadges) { badge in
                        MediaBadgeChip(badge: badge)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    alignment: style == .compactPortrait ? .center : .leading
                )
            }
        }
    }

    private var rootPresentation: HeroPresentation {
        fallbackPresentation ?? presentation
    }

    private var descriptionText: String? {
        switch mode {
        case .home:
            HeroContentPolicy.homeDescription(for: rootPresentation)
        case .detail:
            HeroContentPolicy.detailDescription(
                focused: presentation,
                root: rootPresentation
            )
        }
    }

    private var effectiveRatingBadge: MediaBadge? {
        switch mode {
        case .home:
            rootPresentation.ratingBadge
        case .detail:
            HeroContentPolicy.ratingBadge(
                focused: presentation,
                root: rootPresentation
            )
        }
    }

    private var effectiveGenres: [String] {
        switch mode {
        case .home:
            GenreDisplayFormatter.displayNames(
                for: rootPresentation.genres
            )
        case .detail:
            HeroContentPolicy.genres(
                focused: presentation,
                root: rootPresentation
            )
        }
    }

    private var effectiveRatings: [ExternalRating] {
        guard !hidesRatings else { return [] }
        switch mode {
        case .home:
            return rootPresentation.ratings
        case .detail:
            return HeroContentPolicy.ratings(
                focused: presentation,
                root: rootPresentation
            )
        }
    }

    private var effectiveTechnicalBadges: [MediaBadge] {
        if let technicalBadgesOverride, !technicalBadgesOverride.isEmpty {
            return technicalBadgesOverride
        }
        return HeroContentPolicy.technicalBadges(
            focused: presentation,
            root: rootPresentation,
            override: technicalBadgesOverride
        )
    }

    private var factComponents: [String] {
        HeroContentPolicy.detailFacts(focused: presentation)
    }

}

private struct PlozziOSDetailCredits: View {
    @Environment(\.themePalette) private var palette

    let focused: HeroPresentation
    let root: HeroPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if root.isAnime, !root.studios.isEmpty {
                credit("Studio", values: root.studios)
            } else if [.movie, .series].contains(root.kind),
                      !root.starringNames.isEmpty {
                credit("Starring", values: root.starringNames)
            }

            if !root.isAnime,
               root.kind == .movie,
               !root.directorNames.isEmpty {
                credit("Director", values: root.directorNames)
            }

            if root.isAnime, let sourceMaterial = root.sourceMaterial {
                credit("Based on", values: [sourceMaterial])
            }
        }
        .multilineTextAlignment(.leading)
        #if DEBUG
        .task(id: root.itemID) {
            PlozzLog.app.info(
                "PLZCREDITS title=\(root.title) kind=\(root.kind.rawValue) "
                    + "anime=\(root.isAnime) starring=\(root.starringNames.count) "
                    + "directors=\(root.directorNames.count) studios=\(root.studios.count)"
            )
        }
        #endif
    }

    private func credit(_ label: String, values: [String]) -> some View {
        let capped = Array(values.prefix(3))
        return (
            Text("\(label) ")
                .foregroundStyle(palette.secondaryText)
            + Text(capped.joined(separator: ", "))
                .foregroundStyle(palette.primaryText)
        )
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

}

private struct PlozziOSHeroMuteButton: View {
    @Environment(\.themePalette) private var palette
    let isMuted: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.primaryText)
        .accessibilityLabel(isMuted ? "Unmute trailer" : "Mute trailer")
    }
}

struct PlozziOSHeroPagingIndicator: View {
    @Environment(\.themePalette) private var palette
    let itemIDs: [String]
    let selectedItemID: String?
    let autoAdvance: Bool
    let autoAdvanceSeconds: Int
    let dwellStart: Date
    let trailerController: HeroTrailerController

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !autoAdvance)) { context in
            HStack(spacing: HeroPagingIndicatorMetrics.dotSpacing) {
                ForEach(dotLayout) { dot in
                    indicator(
                        active: dot.index == selectedIndex,
                        scale: HeroPagingIndicatorMetrics.scale(for: dot.size),
                        progress: progress(at: context.date)
                    )
                }
            }
            .frame(
                width: HeroPagingIndicatorMetrics.rowWidth(count: itemIDs.count),
                height: HeroPagingIndicatorMetrics.dotSize
            )
            .animation(
                .easeInOut(duration: HeroPagingIndicatorMetrics.morphDuration),
                value: selectedItemID
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hero item")
            .accessibilityValue(accessibilityValue)
        }
    }

    private var selectedIndex: Int {
        guard let selectedItemID,
              let index = itemIDs.firstIndex(of: selectedItemID) else {
            return 0
        }
        return index
    }

    private var dotLayout: [HeroPagingDots.Dot] {
        HeroPagingDots.layout(
            count: itemIDs.count,
            index: selectedIndex,
            maxVisible: HeroPagingIndicatorMetrics.maxVisible,
            edgeShrink: HeroPagingIndicatorMetrics.edgeShrink
        )
    }

    private func indicator(
        active: Bool,
        scale: CGFloat,
        progress: CGFloat
    ) -> some View {
        let metrics = HeroPagingIndicatorMetrics.self
        let trackWidth = metrics.activeWidth
        let dotSize = metrics.dotSize
        let fillWidth = active
            ? dotSize + (trackWidth - dotSize) * progress
            : 0

        return Capsule()
            .fill(palette.primaryText.opacity(0.28))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(palette.primaryText)
                    .frame(width: fillWidth, height: dotSize)
            }
            .frame(
                width: active ? trackWidth : dotSize * scale,
                height: active ? dotSize : dotSize * scale
            )
            .clipShape(Capsule())
            .frame(
                width: active ? trackWidth : dotSize,
                height: dotSize
            )
    }

    private func progress(at date: Date) -> CGFloat {
        guard autoAdvance else { return 1 }
        if let selectedItemID,
           trailerController.isShowing(selectedItemID) {
            guard trailerController.duration > 0 else { return 0 }
            return min(
                max(
                    CGFloat(
                        trailerController.player.currentTime().seconds
                            / trailerController.duration
                    ),
                    0
                ),
                1
            )
        }
        return min(
            max(
                CGFloat(
                    date.timeIntervalSince(dwellStart)
                        / Double(max(autoAdvanceSeconds, 1))
                ),
                0
            ),
            1
        )
    }

    private var accessibilityValue: String {
        guard let selectedItemID,
              let index = itemIDs.firstIndex(of: selectedItemID) else {
            return ""
        }
        return "\(index + 1) of \(itemIDs.count)"
    }
}

private struct PlozziOSReflectedHeroStage<
    Content: View,
    Reflection: View
>: View {
    @Environment(PlozziOSSidebarGeometryModel.self)
    private var sidebarGeometry
    @State private var windowWidth: CGFloat?

    let height: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content
    @ViewBuilder let reflection: (CGFloat, CGFloat) -> Reflection

    var body: some View {
        GeometryReader { proxy in
            let globalMinX = proxy.frame(in: .global).minX
            let width = windowWidth ?? proxy.size.width
            let locallyCoveredWidth = max(
                proxy.safeAreaInsets.leading,
                globalMinX
            )
            let coveredWidth = max(
                locallyCoveredWidth,
                sidebarGeometry.isVisible
                    ? sidebarGeometry.coveredWidth
                    : 0
            )
            let usableWidth = max(width - coveredWidth, 1)
            let mainOffset = coveredWidth - globalMinX
            ZStack(alignment: .topLeading) {
                if #available(iOS 26.0, *), coveredWidth > 0 {
                    content(usableWidth)
                        .frame(width: usableWidth, height: height)
                        .backgroundExtensionEffect()
                        .offset(x: mainOffset)
                } else {
                    if coveredWidth > 0 {
                        reflection(coveredWidth, usableWidth)
                            .frame(width: coveredWidth, height: height)
                            .offset(x: -globalMinX)
                    }
                    content(usableWidth)
                        .frame(width: usableWidth, height: height)
                        .offset(x: mainOffset)
                }

            }
            .onChange(of: locallyCoveredWidth, initial: true) {
                _, locallyCoveredWidth in
                sidebarGeometry.recordCoveredWidth(locallyCoveredWidth)
            }
            .overlay {
                PlozziOSWindowWidthReader { measuredWidth in
                    guard measuredWidth > 0,
                          windowWidth != measuredWidth else {
                        return
                    }
                    windowWidth = measuredWidth
                }
                .allowsHitTesting(false)
            }
        }
        .frame(height: height)
    }
}

private struct PlozziOSFullWidthHeroStage<Content: View>: View {
    @State private var windowWidth: CGFloat?

    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let globalMinX = proxy.frame(in: .global).minX
            content()
                .frame(
                    width: windowWidth ?? proxy.size.width,
                    height: height
                )
                .offset(x: -globalMinX)
                .overlay {
                    PlozziOSWindowWidthReader { width in
                        guard width > 0, windowWidth != width else { return }
                        windowWidth = width
                    }
                    .allowsHitTesting(false)
                }
        }
        .frame(height: height)
    }
}

private struct PlozziOSWindowWidthReader: UIViewRepresentable {
    let onChange: @MainActor (CGFloat) -> Void

    func makeUIView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReportingView, context: Context) {
        uiView.onChange = onChange
        uiView.report()
    }

    final class ReportingView: UIView {
        var onChange: (@MainActor (CGFloat) -> Void)?
        private var lastWidth: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        func report() {
            guard let width = window?.bounds.width,
                  width > 0,
                  width != lastWidth,
                  let onChange else {
                return
            }
            lastWidth = width
            Task { @MainActor in
                onChange(width)
            }
        }
    }
}

struct PlozziOSWindowSafeAreaTopReader: UIViewRepresentable {
    let onChange: @MainActor (CGFloat) -> Void

    func makeUIView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReportingView, context: Context) {
        uiView.onChange = onChange
        uiView.report()
    }

    final class ReportingView: UIView {
        var onChange: (@MainActor (CGFloat) -> Void)?
        private var lastTop: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        func report() {
            guard let top = window?.safeAreaInsets.top,
                  top != lastTop,
                  let onChange else {
                return
            }
            lastTop = top
            Task { @MainActor in
                onChange(top)
            }
        }
    }
}

struct PlozziOSHomeSidebarOverlapProbe: UIViewControllerRepresentable {
    let enabled: Bool
    let geometryModel: PlozziOSSidebarGeometryModel

    func makeUIViewController(context: Context) -> ProbeController {
        ProbeController()
    }

    func updateUIViewController(
        _ controller: ProbeController,
        context: Context
    ) {
        controller.enabled = enabled
        controller.geometryModel = geometryModel
        controller.apply()
    }

    static func dismantleUIViewController(
        _ controller: ProbeController,
        coordinator: ()
    ) {
        controller.restore()
    }

    @MainActor
    final class ProbeController: UIViewController {
        var enabled = false
        weak var geometryModel: PlozziOSSidebarGeometryModel?
        private weak var owner: UITabBarController?
        private var previousLayout: UITabBarController.Sidebar.Layout?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            Task { @MainActor [weak self] in
                self?.apply()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if enabled {
                apply()
            }
        }

        func apply() {
            guard enabled, let tabs = tabBarController else {
                restore()
                return
            }
            if owner !== tabs {
                restore()
                owner = tabs
                previousLayout = tabs.sidebar.preferredLayout
            }
            tabs.sidebar.preferredLayout = .overlap
            geometryModel?.setVisible(!tabs.sidebar.isHidden)
        }

        func restore() {
            geometryModel?.setVisible(false)
            guard let owner else { return }
            owner.sidebar.preferredLayout = previousLayout ?? .automatic
            self.owner = nil
            previousLayout = nil
        }
    }
}
#endif
