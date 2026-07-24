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
            trailerController: trailerController,
            backgroundSettings: appModel.settings.heroBackground,
            trailerResolver: appModel.heroTrailerResolver()
        ) {
            EmptyView()
        }
    }
}

struct PlozziOSHeroRequest {
    var cta: HeroCTA
    var isRequesting: Bool
    var actingName: String?
    var onRequest: (MediaItem) -> Void
}

/// The shared Seerr request / download-status CTA for both the Home and detail
/// heroes, driven by the canonical `HeroCTA` (CoreModels) so iOS matches tvOS
/// exactly: a filled "Request" button, a plain "Requested" status while queued,
/// and a live "NN%" + progress bar (reusing `ResumeProgressCapsule`) while
/// actually downloading. Renders nothing for owned/unavailable titles.
struct PlozziOSHeroRequestButton: View {
    @Environment(\.themePalette) private var palette
    let item: MediaItem
    let request: PlozziOSHeroRequest

    var body: some View {
        switch request.cta {
        case .request:
            Button {
                request.onRequest(item)
            } label: {
                if request.isRequesting {
                    ProgressView()
                } else {
                    Label("Request", systemImage: "plus.circle")
                }
            }
            .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary))
            .disabled(request.isRequesting)
            .accessibilityLabel(
                request.actingName.map { "Request as \($0)" } ?? "Request"
            )
        case .requested:
            statusPill {
                Label("Requested", systemImage: "clock")
            }
        case let .downloading(progress):
            statusPill {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                    ResumeProgressCapsule(
                        progress: progress,
                        // The status pill uses the secondary (card) surface, so
                        // the bar's ink tracks the *palette* lightness — dark ink
                        // on a light theme, light ink on dark — not the raw
                        // colour scheme (which left a dark bar on the dark pill).
                        onLight: palette.isLight,
                        width: 54,
                        height: 5,
                        floorsMinimumFill: false
                    )
                    Text("\(Int((progress * 100).rounded()))%")
                        .lineLimit(1)
                }
            }
        case .play, .unavailable:
            EmptyView()
        }
    }

    private func statusPill<Content: View>(
        @ViewBuilder _ label: () -> Content
    ) -> some View {
        Button {} label: { label() }
            .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .secondary))
            .disabled(true)
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
    var heroRequest: PlozziOSHeroRequest?
    var pullDistance: CGFloat = 0

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
            pullDistance: pullDistance,
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
                onPlay: onPlay,
                heroRequest: heroRequest
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
    /// Overscroll pull (points) from the enclosing scroll view. Stretches the
    /// backdrop just like the Home hero; 0 leaves the hero at rest.
    var pullDistance: CGFloat = 0
    let trailerController: HeroTrailerController
    let backgroundSettings: HeroBackgroundSettingsModel
    let trailerResolver: HeroTrailerResolving
    @ViewBuilder let foreground: () -> Foreground

    /// Whether a trailer should autoplay for THIS surface (home vs detail read
    /// their own setting), and the surface's mute *default* (the session mute
    /// itself lives on the shared controller).
    private var surfaceTrailerEnabled: Bool {
        surfaceRole == .home
            ? backgroundSettings.settings.homeTrailerEnabled
            : backgroundSettings.settings.detailTrailerEnabled
    }
    private var surfaceMuteDefault: Bool {
        surfaceRole == .home
            ? backgroundSettings.settings.homeTrailerMuted
            : backgroundSettings.settings.detailTrailerMuted
    }

    private var height: CGFloat {
        PlozziOSHeroMetrics.height(
            style: style,
            surfaceRole: surfaceRole,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    var body: some View {
        // Overscroll stretch, mirroring the Home hero: grow the backdrop by the
        // pull distance and pull it up so its top tracks the finger while the
        // bottom stays put. `ancestorScale` keeps the reflection geometry correct.
        // The extra 2pt top over-scan while pulling guarantees the scaled image
        // covers the screen's top edge — without it, subpixel rounding briefly
        // exposes the window background (a white hairline in light mode). The
        // matching shift at the bottom is invisible: it's inside the fade mask.
        let pullScale = 1 + (pullDistance / max(height, 1))
        let pullOffset = max(pullDistance - (pullScale - 1) * height / 2, 0)
            + (pullDistance > 0 ? 2 : 0)
        return ZStack {
            if showsBackdrop {
                PlozziOSReflectedHeroStage(height: height, ancestorScale: pullScale) { _ in
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
                .scaleEffect(pullScale, anchor: .center)
                .offset(y: -pullOffset)
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

        }
        .frame(height: height)
        .task(
            id: PlozziOSHeroPlaybackID(
                itemID: item.id,
                isActive: isActive,
                trailerEnabled: surfaceTrailerEnabled,
                role: surfaceRole
            )
        ) {
            await updateTrailerPlayback()
        }
        .onDisappear(perform: releaseTrailerSurface)
    }

    private func updateTrailerPlayback() async {
        guard isActive, surfaceTrailerEnabled else {
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
            // Already rolling for this item — keep the live (session) mute; don't
            // reset it to the default.
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
            muted: surfaceMuteDefault
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
    let trailerEnabled: Bool
    let role: HeroTrailerSurfaceRole
}

private struct PlozziOSHeroBackdrop: View {
    @Environment(\.themePalette) private var palette

    let presentation: HeroPresentation
    let style: HeroArtworkStyle
    let itemID: String
    let height: CGFloat
    let showsScrim: Bool
    var showsTrailer: Bool = true
    var appliesFadeMask: Bool = true
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

            if showsTrailer,
               trailerController.currentItemID == itemID,
               trailerController.isPlaying {
                HeroTrailerVideoLayer(
                    controller: trailerController,
                    role: surfaceRole
                )
                .transition(.opacity)
            }

            // Gentle black legibility darkening behind the title (kept true to the
            // image, not a grey wash).
            if showsScrim {
                PlozziOSHeroLegibilityScrim(style: style)
            }
        }
        .frame(height: height)
        // Dissolve the whole stack (image + trailer + scrim) to transparent at the
        // bottom so it melts into the page via ALPHA — the tvOS approach. The
        // image keeps its true colours and gently reveals the page, instead of
        // being painted over with an opaque grey that reads as muddy.
        .mask {
            if appliesFadeMask {
                PlozziOSHeroFadeMask()
            } else {
                Rectangle().fill(.white)
            }
        }
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

struct PlozziOSHeroFadeMask: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                // Begin the dissolve at the tvOS start point (~0.33) and ease it out
                // over a long, many-stepped tail so opacity approaches zero
                // asymptotically — no perceptible edge where the hero meets the page
                // background at the very bottom.
                .init(color: .black, location: 0.33),
                .init(color: .black.opacity(0.94), location: 0.48),
                .init(color: .black.opacity(0.80), location: 0.60),
                .init(color: .black.opacity(0.60), location: 0.72),
                .init(color: .black.opacity(0.40), location: 0.82),
                .init(color: .black.opacity(0.22), location: 0.90),
                .init(color: .black.opacity(0.10), location: 0.955),
                .init(color: .black.opacity(0.03), location: 0.985),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// A gentle BLACK legibility darkening for the hero (bottom + landscape leading),
/// designed to sit UNDER the dissolve mask: it deepens the image cleanly behind
/// the title (rather than washing it grey) and is carried to the page background
/// by the enclosing dissolve — mirroring the tvOS hero, which keeps the image's
/// true colours and fades it to transparent instead of painting grey over it.
struct PlozziOSHeroLegibilityScrim: View {
    let style: HeroArtworkStyle

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.34),
                    .init(color: .black.opacity(0.20), location: 0.52),
                    .init(color: .black.opacity(0.44), location: 0.70),
                    .init(color: .black.opacity(0.60), location: 0.86),
                    .init(color: .black.opacity(0.66), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if style == .landscape {
                LinearGradient(
                    colors: [.black.opacity(0.45), .clear],
                    startPoint: .leading,
                    endPoint: .center
                )
            }
        }
    }
}

/// The static legibility scrim overlay for the Home carousel. Rendered once over
/// the cross-fading images and carried to the page by the container's dissolve
/// mask, so it never shifts during a swipe.
struct PlozziOSStationaryHeroScrim: View {
    let style: HeroArtworkStyle
    let height: CGFloat

    var body: some View {
        PlozziOSFullWidthHeroStage(height: height) {
            PlozziOSHeroLegibilityScrim(style: style)
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
    /// Horizontal slide applied to the backdrop CONTENT (inside the reflected
    /// stage, so the stage's own self-alignment isn't disturbed — offsetting the
    /// whole stage makes it re-read its global frame and cancel the move). 0 at
    /// rest, so a settled slide matches the idle backdrop exactly (no snap).
    var contentOffsetX: CGFloat = 0
    /// Suppress the trailer while sliding (image-only) — the trailer resumes on
    /// the idle backdrop once the transition settles.
    var showsTrailer: Bool = true
    /// Transition artwork carries adjacent reflected edge panels. At rest the
    /// sharp center is pixel-identical to the ordinary idle backdrop.
    var usesSlidingArtwork: Bool = false
    /// An outer visual zoom changes `frame(in: .global)` without changing layout.
    /// Pass it through so the reflected stage can recover its pre-zoom position.
    var ancestorScale: CGFloat = 1

    var body: some View {
        let presentation = HeroPresentation(
            item: item,
            artworkStyle: style,
            surface: .home
        )
        PlozziOSReflectedHeroStage(
            height: height,
            ancestorScale: ancestorScale
        ) { usableWidth in
            if usesSlidingArtwork {
                PlozziOSSlidingHeroArtwork(
                    presentation: presentation,
                    width: usableWidth,
                    height: height,
                    offsetX: contentOffsetX
                )
            } else {
                PlozziOSHeroBackdrop(
                    presentation: presentation,
                    style: style,
                    itemID: item.id,
                    height: height,
                    showsScrim: false,
                    showsTrailer: showsTrailer,
                    appliesFadeMask: false,
                    ignoresHorizontalSafeArea: false,
                    surfaceRole: .home,
                    trailerController: trailerController
                )
            }
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

private struct PlozziOSSlidingHeroArtwork: View {
    @Environment(\.themePalette) private var palette

    let presentation: HeroPresentation
    let width: CGFloat
    let height: CGFloat
    let offsetX: CGFloat

    private var edgeWidth: CGFloat {
        width * 0.45
    }

    var body: some View {
        HStack(spacing: 0) {
            mirroredEdge(alignment: .trailing)
            artwork
            mirroredEdge(alignment: .leading)
        }
        .frame(width: width + (edgeWidth * 2), height: height)
        .offset(x: offsetX)
        .frame(width: width, height: height)
        .clipped()
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var artwork: some View {
        FallbackAsyncImage(
            references: presentation.artworkReferences,
            variant: .heroBackdrop
        ) {
            palette.backgroundBase
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func mirroredEdge(alignment: Alignment) -> some View {
        FallbackAsyncImage(
            references: presentation.artworkReferences,
            variant: .heroBackdrop
        ) {
            palette.backgroundBase
        }
        .frame(width: width, height: height)
        .scaleEffect(x: -1)
        .frame(width: edgeWidth, height: height, alignment: alignment)
        .clipped()
        .frame(width: edgeWidth, height: height)
        .clipped()
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
    var heroRequest: PlozziOSHeroRequest?

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

            // Keep the actions on a single row: try the full Play pill first, then
            // shrink its resume trailing (drop "• 58m", then hide the text, keeping
            // the progress bar) so the row fits instead of wrapping. A vertical
            // stack is only the last resort (e.g. very large Dynamic Type).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actionButtons(resumeTrailingStyle: .full) }
                HStack(spacing: 12) { actionButtons(resumeTrailingStyle: .seasonEpisodeOnly) }
                HStack(spacing: 12) { actionButtons(resumeTrailingStyle: .hidden) }
                VStack(spacing: 12) { actionButtons(resumeTrailingStyle: .full) }
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
    private func actionButtons(
        resumeTrailingStyle: PlayResumeButtonLabel.ResumeTrailingStyle
    ) -> some View {
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
                    capsuleWidth: 60,
                    resumeTrailingStyle: resumeTrailingStyle
                )
            }
            .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary))
        }

        heroRequestButton

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
            let infoIsPrimary = !hasPlayAction && !showsRequestPrimary
            NavigationLink {
                PlozziOSItemDetailView(
                    appModel: appModel,
                    provider: provider,
                    item: detailItem,
                    seerService: appModel.seerService
                )
            } label: {
                if infoIsPrimary {
                    Label("More Info", systemImage: "info.circle")
                } else {
                    Image(systemName: "info.circle")
                        .font(.headline.weight(.semibold))
                }
            }
            .buttonStyle(
                PlozziOSHeroActionButtonStyle(
                    kind: infoIsPrimary ? .primary : .secondary,
                    circular: !infoIsPrimary
                )
            )
            .accessibilityLabel("More Info")
        }
    }

    /// One-tap Seerr request CTA for a discovery movie, matching the detail hero.
    @ViewBuilder
    private var heroRequestButton: some View {
        if let heroRequest {
            PlozziOSHeroRequestButton(item: item, request: heroRequest)
        }
    }

    /// Whether the request pill provides the leading (primary-ish) action, so
    /// "More Info" should step down to a secondary circular button.
    private var showsRequestPrimary: Bool {
        guard let heroRequest else { return false }
        switch heroRequest.cta {
        case .request, .requested, .downloading: return true
        case .play, .unavailable: return false
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
    var heroRequest: PlozziOSHeroRequest?

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

    private var hasSourceVersionOptions: Bool {
        sources.count > 1 || versions.count > 1
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

            // Progressive overflow: try every inline layout from "all buttons
            // inline" down to "everything in the … menu", collapsing ONE action
            // at a time (least-important first). ViewThatFits picks the first
            // candidate that fits the hero's width, so actions only fold into "…"
            // when they'd otherwise wrap — and the same page always lays out the
            // same way for a given width.
            ViewThatFits(in: .horizontal) {
                ForEach(0...orderedInlineExtras.count, id: \.self) { collapseCount in
                    actionRow(collapsing: collapseCount)
                }
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

    /// A secondary hero action that can either sit inline as its own button or
    /// fold into the "…" overflow menu. Ordered most-important-first in
    /// `orderedInlineExtras`; the progressive layout collapses from the tail, so
    /// the least-used action is the first to move into "…".
    private enum InlineExtra: Identifiable {
        case primary(ActionEntry)
        case download

        var id: String {
            switch self {
            case .primary(let entry): return "media.\(entry.action.rawValue)"
            case .download: return "download"
            }
        }
    }

    /// Collapsible inline actions in keep-inline priority order (index 0 collapses
    /// last). Play + Request are structural and always stay inline, so they're not
    /// listed here. Everyday actions (watchlist / mark-watched) outrank the
    /// power-user Download, which folds into "…" first as width shrinks.
    private var orderedInlineExtras: [InlineExtra] {
        var extras = primaryActions.map { InlineExtra.primary($0) }
        if downloadItem != nil {
            extras.append(.download)
        }
        return extras
    }

    /// One candidate row that keeps the highest-priority extras inline and folds
    /// the last `collapseCount` of them into the "…" menu. ViewThatFits chooses the
    /// widest candidate (fewest collapsed) that still fits the hero width.
    private func actionRow(collapsing collapseCount: Int) -> some View {
        let extras = orderedInlineExtras
        let keep = max(0, extras.count - collapseCount)
        let inline = Array(extras.prefix(keep))
        let collapsed = Array(extras.suffix(collapseCount))
        let menu = menuActions(collapsing: collapsed)
        return HStack(spacing: 12) {
            playActionButton
            heroRequestButton
            ForEach(inline) { extra in
                inlineExtraButton(extra)
            }
            if hasSourceVersionOptions || !menu.isEmpty {
                sourceVersionMenuButton(actions: menu)
            }
        }
    }

    /// Overflow-menu entries for the collapsed extras, preserving the canonical
    /// menu ordering (primary actions, then Download) regardless of which subset
    /// happens to be collapsed at the current width.
    private func menuActions(collapsing extras: [InlineExtra]) -> [PlaybackSourceMenuAction] {
        let ids = Set(extras.map(\.id))
        return compactPanelActions.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func inlineExtraButton(_ extra: InlineExtra) -> some View {
        switch extra {
        case .primary(let entry):
            primaryActionButton(entry)
        case .download:
            downloadActionButton
        }
    }

    /// The Seerr request CTA for a discovery (not-in-library) title — matching
    /// tvOS, which surfaces Request in the hero itself rather than in a separate
    /// block. Uses the shared `PlozziOSHeroRequestButton` so Home and detail read
    /// identically (Request / Requested / live download progress).
    @ViewBuilder
    private var heroRequestButton: some View {
        if let heroRequest {
            PlozziOSHeroRequestButton(item: item, request: heroRequest)
        }
    }


    @ViewBuilder
    private var playActionButton: some View {
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
    }

    @ViewBuilder
    private func primaryActionButton(_ entry: ActionEntry) -> some View {
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

    @ViewBuilder
    private var downloadActionButton: some View {
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

    private func sourceVersionMenuButton(
        actions: [PlaybackSourceMenuAction] = []
    ) -> some View {
        PlaybackSourceMenuButton(
            sources: sources,
            selectedSourceID: selectedSourceAccountID,
            versions: versions,
            selectedVersionID: selectedVersionID,
            actions: actions,
            onSelectSource: onSelectSource,
            onSelectVersion: onSelectVersion,
            onPerformAction: performCompactPanelAction
        ) {
            Image(systemName: "ellipsis")
                .font(.headline.weight(.bold))
        }
        .buttonStyle(
            PlozziOSHeroActionButtonStyle(
                kind: .secondary,
                circular: true
            )
        )
        .accessibilityLabel("More actions")
    }

    private var compactPanelActions: [PlaybackSourceMenuAction] {
        var result = primaryActions.map { entry in
            PlaybackSourceMenuAction(
                id: "media.\(entry.action.rawValue)",
                title: entry.action.title,
                systemImage: primaryActionSymbol(for: entry)
            )
        }
        if downloadItem != nil {
            result.append(PlaybackSourceMenuAction(
                id: "download",
                title: downloadActionTitle,
                systemImage: downloadActionSymbol
            ))
        }
        return result
    }

    private func performCompactPanelAction(_ id: String) {
        if id == "download" {
            Task { await performDownloadAction() }
            return
        }
        guard id.hasPrefix("media."),
              let entry = primaryActions.first(where: {
                  "media.\($0.action.rawValue)" == id
              }) else {
            return
        }
        actionHandler.perform(entry.action, on: entry.target, context: .none)
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
        sourceVersionMenuActions
    }

    @ViewBuilder
    private var sourceVersionMenuActions: some View {
        if sources.count > 1, let selectedSource {
            Picker(
                selection: Binding(
                    get: { selectedSource.accountID },
                    set: onSelectSource
                )
            ) {
                ForEach(sources) { source in
                    Text(source.displayName)
                        .tag(source.accountID)
                }
            } label: {
                Label(selectedSource.displayName, systemImage: "server.rack")
            }
            .pickerStyle(.menu)
        }
        if versions.count > 1, let selectedVersion {
            Picker(
                selection: Binding(
                    get: { selectedVersion.id },
                    set: onSelectVersion
                )
            ) {
                ForEach(versions.sortedForPicker()) { version in
                    Text(version.displayLabel)
                        .tag(version.id)
                }
            } label: {
                Label(selectedVersion.displayLabel, systemImage: "film.stack")
            }
            .pickerStyle(.menu)
        }
    }

    private var selectedSource: MediaSourceRef? {
        sources.first { $0.accountID == selectedSourceAccountID }
            ?? sources.first
    }

    private var selectedVersion: MediaVersion? {
        versions.first { $0.id == selectedVersionID } ?? versions.first
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
                Text(descriptionText.overviewMarkdownWithLegibleLinks(
                    textColor: palette.primaryText,
                    accent: palette.accent
                ))
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

struct PlozziOSTrailerMuteToolbarButton: View {
    let isMuted: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
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
    var ancestorScale: CGFloat = 1
    @ViewBuilder let content: (CGFloat) -> Content
    @ViewBuilder let reflection: (CGFloat, CGFloat) -> Reflection

    var body: some View {
        GeometryReader { proxy in
            let scaledGlobalMinX = proxy.frame(in: .global).minX
            let horizontalScaleGrowth = proxy.size.width
                * (max(ancestorScale, 1) - 1) / 2
            let globalMinX = scaledGlobalMinX + horizontalScaleGrowth
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
        private var previousStandardAppearance: UITabBarAppearance?
        private var previousScrollEdgeAppearance: UITabBarAppearance?
        private var didApplyTransparency = false

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
                previousStandardAppearance = tabs.tabBar.standardAppearance
                previousScrollEdgeAppearance =
                    tabs.tabBar.scrollEdgeAppearance
                didApplyTransparency = false
            }
            if !didApplyTransparency {
                didApplyTransparency = true
                tabs.sidebar.preferredLayout = .overlap
                let transparentAppearance = UITabBarAppearance()
                transparentAppearance.configureWithTransparentBackground()
                transparentAppearance.backgroundEffect = nil
                transparentAppearance.backgroundColor = .clear
                transparentAppearance.shadowColor = .clear
                tabs.tabBar.standardAppearance = transparentAppearance
                tabs.tabBar.scrollEdgeAppearance = transparentAppearance
                tabs.tabBar.isTranslucent = true
            }
            geometryModel?.setVisible(!tabs.sidebar.isHidden)
        }

        func restore() {
            geometryModel?.setVisible(false)
            didApplyTransparency = false
            guard let owner else { return }
            owner.sidebar.preferredLayout = previousLayout ?? .automatic
            if let previousStandardAppearance {
                owner.tabBar.standardAppearance = previousStandardAppearance
            }
            owner.tabBar.scrollEdgeAppearance = previousScrollEdgeAppearance
            self.owner = nil
            previousLayout = nil
            previousStandardAppearance = nil
            previousScrollEdgeAppearance = nil
        }
    }
}
#endif
