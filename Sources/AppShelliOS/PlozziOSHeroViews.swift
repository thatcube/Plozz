#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI
import UIKit

enum PlozziOSHeroMetrics {
    static func height(
        style: HeroArtworkStyle,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        let base: CGFloat = style == .compactPortrait ? 610 : 540
        guard dynamicTypeSize.isAccessibilitySize else { return base }
        return base + (style == .compactPortrait ? 160 : 120)
    }
}

struct PlozziOSHomeHeroSlide: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(HeroTrailerController.self) private var trailerController
    @Environment(PlozziOSAppModel.self) private var appModel

    let item: MediaItem
    let provider: (any MediaProvider)?
    let isSelected: Bool
    let onPlay: (MediaItem) -> Void

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
            trailerController: trailerController,
            backgroundSettings: appModel.settings.heroBackground,
            trailerResolver: appModel.heroTrailerResolver()
        ) {
            PlozziOSHomeHeroForeground(
                item: item,
                presentation: presentation,
                style: style,
                provider: provider,
                onPlay: onPlay
            )
        }
    }
}

struct PlozziOSDetailHeroSection: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(HeroTrailerController.self) private var trailerController
    @Environment(PlozziOSAppModel.self) private var appModel

    let item: MediaItem
    let playableItem: MediaItem?
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
        PlozziOSHeroStage(
            item: item,
            presentation: presentation,
            style: style,
            surfaceRole: .detail,
            isActive: true,
            trailerController: trailerController,
            backgroundSettings: appModel.settings.heroBackground,
            trailerResolver: appModel.heroTrailerResolver()
        ) {
            PlozziOSDetailHeroForeground(
                item: item,
                playableItem: playableItem,
                presentation: presentation,
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
    let trailerController: HeroTrailerController
    let backgroundSettings: HeroBackgroundSettingsModel
    let trailerResolver: HeroTrailerResolving
    @ViewBuilder let foreground: () -> Foreground

    private var height: CGFloat {
        PlozziOSHeroMetrics.height(
            style: style,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    var body: some View {
        ZStack {
            PlozziOSFullWidthHeroStage(height: height) {
                PlozziOSHeroBackdrop(
                    presentation: presentation,
                    itemID: item.id,
                    height: height,
                    surfaceRole: surfaceRole,
                    trailerController: trailerController
                )
            }

            foreground()
                .frame(maxWidth: style == .compactPortrait ? 560 : 760)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: style == .compactPortrait
                        ? .bottom
                        : .bottomLeading
                )
                .padding(.horizontal, style == .compactPortrait ? 22 : 36)
                .padding(.bottom, style == .compactPortrait ? 30 : 42)

            if backgroundSettings.settings.mode == .trailer,
               trailerController.currentItemID == item.id {
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
            return
        }
        guard let source = await trailerResolver(item),
              !Task.isCancelled else {
            return
        }
        trailerController.play(
            itemID: item.id,
            resolvedURL: source.url,
            muted: backgroundSettings.settings.trailerMuted
        )
        trailerController.claimSurface(surfaceRole, itemID: item.id)
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
    let itemID: String
    let height: CGFloat
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

            if trailerController.currentItemID == itemID {
                HeroTrailerVideoLayer(
                    controller: trailerController,
                    role: surfaceRole
                )
                .transition(.opacity)
            }

            LinearGradient(
                colors: [
                    .black.opacity(0.08),
                    .black.opacity(0.2),
                    .black.opacity(0.72),
                    palette.backgroundBase
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [.black.opacity(0.62), .clear],
                startPoint: .leading,
                endPoint: .center
            )
        }
        .frame(height: height)
        .clipped()
        .ignoresSafeArea(edges: [.top, .horizontal])
    }
}

private struct PlozziOSHomeHeroForeground: View {
    @Environment(PlozziOSAppModel.self) private var appModel

    let item: MediaItem
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
                style: style
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
        if !item.isNotInLibraryDiscovery,
           item.kind == .movie
            || item.kind == .episode
            || item.kind == .video {
            Button {
                onPlay(item)
            } label: {
                Label(
                    presentation.isResumable ? "Resume" : "Play",
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
        }

        if let provider {
            NavigationLink {
                PlozziOSItemDetailView(
                    appModel: appModel,
                    provider: provider,
                    item: item,
                    seerService: appModel.seerService
                )
            } label: {
                Label("More Info", systemImage: "info.circle")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct PlozziOSDetailHeroForeground: View {
    let item: MediaItem
    let playableItem: MediaItem?
    let presentation: HeroPresentation
    let style: HeroArtworkStyle
    let actionHandler: any MediaItemActionHandling
    let onPlay: (MediaItem, Bool) -> Void

    private var actions: [MediaItemAction] {
        actionHandler.actions(for: item, context: .none)
            .filter { !$0.isNavigation }
    }

    var body: some View {
        VStack(
            alignment: style == .compactPortrait ? .center : .leading,
            spacing: 12
        ) {
            PlozziOSHeroMetadata(
                presentation: presentation,
                style: style
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
        if let playableItem {
            Button {
                onPlay(playableItem, false)
            } label: {
                Label(
                    presentation.isResumable ? "Resume" : "Play",
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)

            if presentation.isResumable {
                Button {
                    onPlay(playableItem, true)
                } label: {
                    Label(
                        "Start Over",
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .buttonStyle(.bordered)
            }
        }

        if !actions.isEmpty {
            Menu {
                ForEach(actions) { action in
                    Button(
                        action.title,
                        systemImage: action.systemImage
                    ) {
                        actionHandler.perform(
                            action,
                            on: item,
                            context: .none
                        )
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct PlozziOSHeroMetadata: View {
    let presentation: HeroPresentation
    let style: HeroArtworkStyle

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
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }

            if presentation.certification != nil
                || presentation.metadataText != nil {
                HStack(spacing: 10) {
                    if let certification = presentation.certification {
                        Text(certification)
                            .font(.caption.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.white.opacity(0.8))
                            }
                    }
                    if let metadata = presentation.metadataText {
                        Text(metadata)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white.opacity(0.92))
            }

            if let tagline = presentation.tagline {
                Text(tagline)
                    .font(.headline.italic())
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }

            if let overview = presentation.overview {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(style == .compactPortrait ? 3 : 4)
                    .frame(maxWidth: style == .compactPortrait ? 500 : 700)
            }
        }
    }
}

private struct PlozziOSHeroMuteButton: View {
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
        .foregroundStyle(.white)
        .accessibilityLabel(isMuted ? "Unmute trailer" : "Mute trailer")
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
#endif
