#if os(iOS)
import AVFoundation
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import HeroUI
import MediaDownloads
import MetadataKit
import Observation
import SwiftUI
import UIKit

enum PlozziOSHeroMetrics {
    /// Whether this hero fills its stage by **mirroring** its own bottom edge
    /// into the space the picture doesn't reach, rather than by cropping the
    /// picture until it does.
    ///
    /// Only the portrait Home hero: it is the one that stands a fixed fraction
    /// of the window tall (see ``HeroStageMetrics``) regardless of how the
    /// artwork is shaped, so it is the one whose crop would otherwise be
    /// dictated by the length of the phone. The detail hero is the top of a
    /// scrolling page rather than a full screen, and a regular-width layout puts
    /// its metadata in a side column where height is not the constraint.
    static func extendsArtwork(
        style: HeroArtworkStyle,
        surfaceRole: HeroTrailerSurfaceRole
    ) -> Bool {
        style == .compactPortrait && surfaceRole == .home
    }

    static func height(
        style: HeroArtworkStyle,
        surfaceRole: HeroTrailerSurfaceRole,
        dynamicTypeSize: DynamicTypeSize,
        containerHeight: CGFloat? = nil
    ) -> CGFloat {
        let accessibilityExtra: CGFloat = dynamicTypeSize.isAccessibilitySize
            ? (style == .compactPortrait ? 160 : 140)
            : 0
        // The portrait Home hero is sized to the phone, not to a constant: it
        // has to reach far enough down that the metadata sits in the lower part
        // of the screen, while still leaving the next row peeking. See
        // `HeroStageMetrics`.
        if extendsArtwork(style: style, surfaceRole: surfaceRole) {
            return HeroStageMetrics.portraitHomeHeight(
                windowHeight: containerHeight,
                fallback: 610,
                accessibilityExtra: accessibilityExtra
            )
        }
        let base: CGFloat = style == .compactPortrait
            ? 610
            : (surfaceRole == .detail ? 760 : 680)
        return base + accessibilityExtra
    }

}

/// The height of the window the hero is standing in, so a portrait Home hero can
/// be sized to the phone (see ``HeroStageMetrics``).
///
/// The **window**, not the safe area: the hero runs full-bleed under the status
/// bar and the peek it leaves is measured against the bottom of the screen, so a
/// height that already had the insets taken out of it would size the hero to the
/// wrong thing — and differently on every phone, which is the problem this is
/// here to solve. `nil` until the window has been measured, which is what makes
/// the fallback in `PlozziOSHeroMetrics.height` reachable.
private struct PlozziOSHeroContainerHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var plozziOSHeroContainerHeight: CGFloat? {
        get { self[PlozziOSHeroContainerHeightKey.self] }
        set { self[PlozziOSHeroContainerHeightKey.self] = newValue }
    }
}

private struct PlozziOSHeroContainerHeightModifier: ViewModifier {
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        content
            .environment(\.plozziOSHeroContainerHeight, height)
            .background {
                PlozziOSWindowHeightReader { measured in
                    guard measured > 0, height != measured else { return }
                    height = measured
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

extension View {
    /// Publishes the window's height to every hero below, so they can size
    /// themselves to the phone. See ``EnvironmentValues/plozziOSHeroContainerHeight``.
    func plozziOSTracksHeroContainerHeight() -> some View {
        modifier(PlozziOSHeroContainerHeightModifier())
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

    /// The hero's title logo, capped so it can never be wider than the column it
    /// sits in. A logo wider than `heroTextMaxWidth` used to overhang the column
    /// and, because the column centres oversized content, drag every row of the
    /// hero left with it — but only for titles whose logo actually reached the
    /// cap, which is why some heroes looked indented and others didn't.
    static func heroLogoMaxWidth(for style: HeroArtworkStyle) -> CGFloat {
        min(style == .compactPortrait ? 330 : 520, heroTextMaxWidth(for: style))
    }

    /// Nominal height budget for the hero wordmark.
    static func heroLogoMaxHeight(for style: HeroArtworkStyle) -> CGFloat {
        style == .compactPortrait ? 95 : 130
    }

    /// The box handed to `HeroLogoArtwork`, with the wordmark's *drawn* width
    /// pinned to the column rather than merely budgeted against it.
    ///
    /// ``heroLogoMaxWidth`` alone did not deliver the cap it describes: `HeroLogoFit`
    /// flexes a wide shape to ``HeroLogoFit/widthFlex`` past its box, so a wide
    /// wordmark still overhung the column and still dragged the hero's rows left.
    /// Pinning holds every logo wide enough to reach the column to the *same* drawn
    /// width, and returns the width it takes as height so no logo shrinks.
    static func heroLogoBox(for style: HeroArtworkStyle) -> CGSize {
        let column = heroLogoMaxWidth(for: style)
        return HeroLogoFit.pinnedBox(
            budget: CGSize(width: column, height: heroLogoMaxHeight(for: style)),
            drawnWidth: column
        )
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

/// The one definition of where Home's hero foreground sits inside the hero
/// stage: width cap, bottom-leading pin, horizontal inset and bottom padding.
///
/// Applied by BOTH the real foreground (`PlozziOSHomeHeroCarousel`) and its
/// loading placeholder (`PlozziOSHomeHeroSkeleton`). It exists because the
/// placeholder originally copied these constants by hand and drifted from the
/// real hero — wrong indent, wrong vertical position. Screen sizes vary, so the
/// two must derive from the same code, not from matching numbers.
struct PlozziOSHeroForegroundPlacement: ViewModifier {
    let style: HeroArtworkStyle

    func body(content: Content) -> some View {
        content
            // The column fills its capped width and aligns inside it. Part of the
            // shared placement so the placeholder gets it too.
            .frame(
                maxWidth: .infinity,
                alignment: style == .compactPortrait ? .center : .leading
            )
            // Alignment is not optional here: without it the cap centres anything
            // too wide to fit, so an oversized child overhangs both edges and
            // moves the column's origin instead of just its own trailing edge.
            .frame(
                maxWidth: PlozziOSPageLayout.heroTextMaxWidth(for: style),
                alignment: style == .compactPortrait ? .center : .leading
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: style == .compactPortrait ? .bottom : .bottomLeading
            )
            .padding(.horizontal, PlozziOSPageLayout.horizontalInset(for: style))
            .padding(.bottom, style == .compactPortrait ? 30 : 42)
    }
}

extension View {
    /// See ``PlozziOSHeroForegroundPlacement``.
    func plozziOSHeroForegroundPlacement(style: HeroArtworkStyle) -> some View {
        modifier(PlozziOSHeroForegroundPlacement(style: style))
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
    /// For a **series**: the loaded Seerr season-request availability (nil while it
    /// loads), plus a per-season request callback. When both are present and there
    /// is season content, the Request CTA becomes a season-picker menu ("Request
    /// All Seasons" + per-season) instead of a one-tap whole-title request. Movies
    /// (and series whose availability hasn't loaded yet) keep the one-tap button.
    var seasonAvailability: MediaRequestAvailability? = nil
    var onRequestSeasons: (([Int]) -> Void)? = nil
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
            if item.kind == .series,
               let onRequestSeasons = request.onRequestSeasons,
               let availability = request.seasonAvailability,
               availability.hasSeasonRequestContent {
                Menu {
                    SeasonRequestMenuContent(
                        availability: availability,
                        onRequest: onRequestSeasons
                    )
                } label: {
                    requestLabel
                }
                .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary))
                .disabled(request.isRequesting)
                .accessibilityLabel(
                    request.actingName.map { "Request seasons as \($0)" }
                        ?? "Request seasons"
                )
            } else {
                Button {
                    request.onRequest(item)
                } label: {
                    requestLabel
                }
                .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary))
                .disabled(request.isRequesting)
                .accessibilityLabel(
                    request.actingName.map { "Request as \($0)" } ?? "Request"
                )
            }
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

    @ViewBuilder
    private var requestLabel: some View {
        if request.isRequesting {
            ProgressView()
        } else {
            Label("Request", systemImage: "plus.circle")
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
    /// The air-schedule badge for a series, resolved by the detail page.
    var scheduleLine: LocalizedStringResource? = nil
    let selectedSourceAccountID: String?
    let versions: [MediaVersion]
    let selectedVersionID: String?
    let onSelectSource: (String) -> Void
    let onSelectVersion: (String) -> Void
    let actionHandler: any MediaItemActionHandling
    let onPlay: (MediaItem, Bool) -> Void
    var trailerItem: MediaItem?
    var onPlayTrailer: ((MediaItem) -> Void)?
    var heroRequest: PlozziOSHeroRequest?
    /// Forwarded to the action row — see `offersParentNavigation` there.
    var offersParentNavigation: Bool = false
    /// Forwarded to the action row — see `presentsEpisodeStill` there.
    var presentsEpisodeStill: Bool = false
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
            // An episode page has no full-bleed backdrop: the themed page
            // background shows through and the episode's own still leads
            // instead. The show's artwork here made every episode look the same.
            showsBackdrop: !presentsEpisodeStill,
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
                scheduleLine: scheduleLine,
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
                trailerItem: trailerItem,
                onPlayTrailer: onPlayTrailer,
                heroRequest: heroRequest,
                offersParentNavigation: offersParentNavigation,
                presentsEpisodeStill: presentsEpisodeStill
            )
        }
    }
}

private struct PlozziOSHeroStage<Foreground: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.plozziOSHeroContainerHeight) private var containerHeight

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
            dynamicTypeSize: dynamicTypeSize,
            containerHeight: containerHeight
        )
    }

    private var extendsArtwork: Bool {
        PlozziOSHeroMetrics.extendsArtwork(
            style: style,
            surfaceRole: surfaceRole
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
                        extendsArtwork: extendsArtwork,
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

/// A hero's artwork laid into a stage **taller than the picture**, with the
/// shortfall filled by a mirrored continuation of the picture's own bottom edge.
///
/// The same trick a Continue Watching card uses, and deliberately the same
/// geometry (``HeroStageMetrics`` delegating to ``ExtendedArtworkGeometry``)
/// rather than a second implementation of it. The portrait Home hero has to
/// stand about three quarters of the phone tall so its metadata sits low; a hero
/// that simply *filled* that slot would crop 16:9 backdrop art past 3x, and
/// would crop it by a different amount on every phone. Mirroring buys the height
/// back and leaves the picture alone.
///
/// The picture is handed a `layout` rather than a plain size because the flipped
/// copy is not free to render everything the upright one does — see
/// ``PlozziOSHeroPictureLayout/isMirror``.
private struct PlozziOSExtendedHeroArtwork<Picture: View>: View {
    /// How far the mirror is drawn up *behind* the picture's bottom edge, so the
    /// two overlap instead of meeting at a line that splits open the moment the
    /// hero is scaled by an overscroll pull. Same reasoning, and same value, as
    /// a Continue Watching card's seam overlap.
    private static var seamOverlap: CGFloat { 2 }

    let height: CGFloat
    @ViewBuilder let picture: (PlozziOSHeroPictureLayout) -> Picture

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let geometry = HeroStageMetrics.geometry(
                width: width,
                height: height
            )
            ZStack(alignment: .top) {
                sizedPicture(geometry, isMirror: false)
                if geometry.reflectionHeight > 0 {
                    mirror(geometry, width: width)
                        .offset(y: geometry.pictureHeight - Self.seamOverlap)
                }
            }
            // ONE clip, on the outside. The picture is rendered wider than the
            // stage whenever a side trim is in play, and the mirror overruns the
            // foot; both are cut here rather than each carrying its own
            // rasterisation boundary along the seam.
            .frame(width: width, height: height, alignment: .top)
            .clipped()
        }
        .frame(height: height)
    }

    private func sizedPicture(
        _ geometry: ExtendedArtworkGeometry,
        isMirror: Bool
    ) -> some View {
        picture(
            PlozziOSHeroPictureLayout(
                width: geometry.renderedWidth,
                height: geometry.pictureHeight,
                isMirror: isMirror
            )
        )
        .frame(width: geometry.renderedWidth, height: geometry.pictureHeight)
    }

    /// The band under the picture: the same image flipped, so its top row is the
    /// picture's last row, then eased away by **alpha** rather than by painting
    /// black over it. A black wash is what a Continue Watching card uses because
    /// it stands on an opaque card; the hero stands on the page, and the page is
    /// white in light mode.
    private func mirror(
        _ geometry: ExtendedArtworkGeometry,
        width: CGFloat
    ) -> some View {
        Color.clear
            .frame(
                width: width,
                height: geometry.reflectionHeight + Self.seamOverlap
            )
            .overlay(alignment: .top) {
                sizedPicture(geometry, isMirror: true)
                    .scaleEffect(x: 1, y: -1)
            }
            .clipped()
            .mask {
                // Full strength at the seam — a reflection is brightest where it
                // meets what it reflects, and any step there is a hard line
                // across the picture. Barely eased after that, because this is
                // NOT the hero's dissolve: the fade mask is still to come and
                // now begins at this very band, so ramping hard here as well
                // dissolved the image twice over and left the buttons sitting on
                // flat page background instead of on the picture.
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.94), location: 0.45),
                        .init(color: .white.opacity(0.82), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }
}

/// The slot ``PlozziOSExtendedHeroArtwork`` is asking a picture to fill.
private struct PlozziOSHeroPictureLayout {
    let width: CGFloat
    let height: CGFloat
    /// True for the flipped copy.
    ///
    /// Callers must not put `HeroTrailerVideoLayer` in a mirrored copy: it does
    /// not create a player layer, it **moves** the controller's single surface
    /// view into whichever host asks last, so a second instance would tear the
    /// trailer out of the upright picture. Mirror the trailer with
    /// `PlozziOSMirrorVideoLayer`, which owns its own layer over the same player
    /// — the same split the sidebar reflection already makes.
    let isMirror: Bool
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
    /// Fill the stage by mirroring the picture's bottom edge instead of cropping
    /// the picture until it fills. See ``PlozziOSExtendedHeroArtwork``.
    var extendsArtwork: Bool = false
    let ignoresHorizontalSafeArea: Bool
    let surfaceRole: HeroTrailerSurfaceRole
    let trailerController: HeroTrailerController

    var body: some View {
        ZStack {
            if extendsArtwork {
                PlozziOSExtendedHeroArtwork(height: height) { layout in
                    artwork(layout: layout)
                        .frame(width: layout.width, height: layout.height)
                        .clipped()
                }
            } else {
                artwork(layout: nil)
            }

            // Gentle black legibility darkening behind the title (kept true to the
            // image, not a grey wash).
            if showsScrim {
                PlozziOSHeroLegibilityScrim(
                    style: style,
                    extendsArtwork: extendsArtwork
                )
            }
        }
        .frame(height: height)
        // Dissolve the whole stack (image + trailer + scrim) to transparent at the
        // bottom so it melts into the page via ALPHA — the tvOS approach. The
        // image keeps its true colours and gently reveals the page, instead of
        // being painted over with an opaque grey that reads as muddy.
        .mask {
            if appliesFadeMask {
                PlozziOSHeroFadeMask(extendsArtwork: extendsArtwork)
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

    /// The picture itself: artwork, plus the trailer once it is rolling.
    ///
    /// `layout` is nil for the ordinary fill-the-stage case and set when this is
    /// being laid into (or mirrored beneath) an extended stage.
    @ViewBuilder
    private func artwork(layout: PlozziOSHeroPictureLayout?) -> some View {
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
                if layout?.isMirror == true {
                    PlozziOSMirrorVideoLayer(player: trailerController.player)
                } else {
                    HeroTrailerVideoLayer(
                        controller: trailerController,
                        role: surfaceRole
                    )
                    .transition(.opacity)
                }
            }
        }
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

/// The hero's bottom dissolve: opaque keeps the image, clear lets the page
/// background show through.
///
/// This is `HomeHeroBackdrop.easedVerticalFade` from tvOS, stop for stop, with
/// the same mode-dependent start. The previous curve began dissolving at 0.33
/// in BOTH modes, which left the image semi-transparent through its whole middle
/// — in dark mode it blended with the page into a flat grey plateau that then
/// met the rows at a visible edge, instead of tvOS's solid image melting away
/// over the last third. The comment claimed it used "the tvOS start point
/// (~0.33)"; tvOS actually holds full opacity until 0.62 in dark mode.
struct PlozziOSHeroFadeMask: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Whether this hero fills its stage by mirroring its own bottom edge (see
    /// ``PlozziOSExtendedHeroArtwork``). When it does, the melt is tied to the
    /// mirror line instead of being a fixed fraction: the picture stays whole
    /// right down to where its reflection begins, and the reflection is what
    /// dissolves. That is the difference between an image that quietly gives up
    /// halfway down the screen — leaving the metadata sitting on flat page
    /// background, which is what a fixed 0.62 produced on a hero this tall — and
    /// one that carries all the way behind the buttons and then melts.
    var extendsArtwork: Bool = false

    /// Where the melt begins. Light mode starts higher because a light page
    /// swallows the artwork's edge sooner; dark mode holds the image longer so
    /// it doesn't wash out against the background.
    private var meltStart: CGFloat {
        colorScheme == .dark ? 0.62 : 0.38
    }

    /// The same idea against the mirror line rather than the whole stage: the
    /// picture is kept whole to the very row where its reflection begins, and
    /// the reflection is what melts into the page. Light mode starts a little
    /// earlier, for the same reason the fixed start does — a pale page swallows
    /// the artwork's edge sooner.
    private var extendedMeltScale: CGFloat {
        colorScheme == .dark ? 1.0 : 0.86
    }

    var body: some View {
        GeometryReader { proxy in
            gradient(start: start(in: proxy.size))
        }
    }

    private func start(in size: CGSize) -> CGFloat {
        guard extendsArtwork, size.width > 0, size.height > 0 else {
            return meltStart
        }
        let mirrorLine = HeroStageMetrics.geometry(
            width: size.width,
            height: size.height
        ).reflectionStart
        return min(max(mirrorLine * extendedMeltScale, meltStart), 0.92)
    }

    private func gradient(start: CGFloat) -> some View {
        let span = max(1 - start, 0.0001)
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: start),
                .init(color: .black.opacity(0.72), location: start + span * 0.32),
                .init(color: .black.opacity(0.36), location: start + span * 0.60),
                .init(color: .black.opacity(0.10), location: start + span * 0.83),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The hero's legibility darkening, delegated to the SHARED
/// ``HeroLegibilityScrim`` so iOS and tvOS render the same shape.
///
/// It used to hand-roll its own gradient, and the shape had drifted badly: the
/// bottom darkening ramped in from 34% and reached 0.66, where the shared
/// vignette stays clear until 58% and only reaches its peak at the very edge.
/// The image was therefore ~0.4-0.6 darkened through its whole middle, which
/// over a light poster produced a flat grey plateau that met the rows at a
/// visible edge instead of melting into them.
///
/// Delegating rather than re-tuning is the point: the two platforms had already
/// drifted twice here (a hardcoded black tone, and this shape), and a shared
/// component is what stops it happening a third time.
struct PlozziOSHeroLegibilityScrim: View {
    @Environment(\.colorScheme) private var colorScheme

    let style: HeroArtworkStyle
    /// Whether the picture now runs all the way down behind the metadata (see
    /// ``PlozziOSHeroFadeMask/extendsArtwork``). It used to fade out around
    /// halfway, so the lower half of the column was reading against flat page
    /// background and barely needed a scrim; with the image still there, the
    /// vignette has to do the job it was always nominally for.
    ///
    /// Only a little deeper, though. The first attempt at this took the peak to
    /// 0.72, which — landing on the same band the fade mask dissolves — turned
    /// the bottom of the hero into a black box with a photograph balanced on top
    /// of it. Legibility here is a collaboration between three things (this, the
    /// mirror's own easing, and the dissolve); any one of them doing the whole
    /// job undoes the effect the other two exist for.
    var extendsArtwork: Bool = false

    private var tone: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        HeroLegibilityScrim(
            tone: tone,
            edgePeak: extendsArtwork ? 0.62 : 0.55,
            // A portrait hero has no room for a side wash; only the landscape
            // layout puts the title in a left-hand column.
            edges: style == .landscape ? [.leading, .bottom] : [.bottom],
            sideDarkeningStart: 0.34
        )
    }
}

/// The static legibility scrim overlay for the Home carousel. Rendered once over
/// the cross-fading images and carried to the page by the container's dissolve
/// mask, so it never shifts during a swipe.
struct PlozziOSStationaryHeroScrim: View {
    let style: HeroArtworkStyle
    let height: CGFloat
    var extendsArtwork: Bool = false

    var body: some View {
        PlozziOSFullWidthHeroStage(height: height) {
            PlozziOSHeroLegibilityScrim(
                style: style,
                extendsArtwork: extendsArtwork
            )
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
    /// Fill the stage by mirroring the picture's bottom edge rather than by
    /// cropping the picture until it fills. See ``PlozziOSExtendedHeroArtwork``.
    var extendsArtwork: Bool = false

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
                slidingArtwork(presentation: presentation, width: usableWidth)
            } else {
                PlozziOSHeroBackdrop(
                    presentation: presentation,
                    style: style,
                    itemID: item.id,
                    height: height,
                    showsScrim: false,
                    showsTrailer: showsTrailer,
                    appliesFadeMask: false,
                    extendsArtwork: extendsArtwork,
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

    /// The swipe-transition artwork. When the stage is mirror-extended the slide
    /// happens inside the **picture band** and the mirror follows it, so a hero
    /// mid-swipe has the same shape as one at rest — the alternative, sliding a
    /// full-height image under a stationary mirror, tears the two apart for the
    /// length of every drag.
    @ViewBuilder
    private func slidingArtwork(
        presentation: HeroPresentation,
        width: CGFloat
    ) -> some View {
        if extendsArtwork {
            PlozziOSExtendedHeroArtwork(height: height) { layout in
                PlozziOSSlidingHeroArtwork(
                    presentation: presentation,
                    width: layout.width,
                    height: layout.height,
                    offsetX: contentOffsetX
                )
            }
        } else {
            PlozziOSSlidingHeroArtwork(
                presentation: presentation,
                width: width,
                height: height,
                offsetX: contentOffsetX
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
    /// "New episode every Friday" for a returning series, from the shared
    /// `HeroScheduleLines` the tvOS hero already uses.
    var scheduleLine: LocalizedStringResource?

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
                    .shouldHideRatings(for: item),
                scheduleLine: scheduleLine
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
        // Width fill / alignment now come from the shared placement modifier.
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
            let isWatchlisted = watchlistAction == .removeFromWatchlist
            Button {
                actionHandler?.perform(
                    watchlistAction,
                    on: watchlistItem,
                    context: .none
                )
            } label: {
                Image(
                    systemName: isWatchlisted
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
            .accessibilityValue(
                isWatchlisted ? "In Watchlist" : "Not in Watchlist"
            )
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
        !DetailOpenEnvironment.isDiscovery(
            item,
            identitySources:
                appModel.identityIndex.identitySourcesProvider
        )
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
    /// The air-schedule badge for a series, resolved by the detail page.
    var scheduleLine: LocalizedStringResource? = nil
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
    var trailerItem: MediaItem?
    var onPlayTrailer: ((MediaItem) -> Void)?
    var heroRequest: PlozziOSHeroRequest?
    /// Whether this hero fronts an item with a parent page worth returning to —
    /// an episode on its own page, reachable from Continue Watching or Search
    /// where Back leaves the show entirely. See `DetailHeroView`.
    var offersParentNavigation: Bool = false
    /// Renders the episode-page hero: the episode's own 16:9 still, inset above
    /// its details, with the show named in a breadcrumb rather than a wordmark.
    /// See `DetailHeroView.presentsEpisodeStill` for the reasoning.
    var presentsEpisodeStill: Bool = false
    @Environment(\.mediaItemNavigator) private var navigator

    private struct ActionEntry: Identifiable {
        let action: MediaItemAction
        let target: MediaItem
        var id: MediaItemAction { action }
    }

    private var actions: [ActionEntry] {
        var seen = Set<MediaItemAction>()
        var entries: [ActionEntry] = []
        // A series page rests its hero on the episode Play would run, and an
        // episode is not watchlistable — so the button did not act on the wrong
        // thing, it vanished. `watchlistSubject` promotes it to its show, the
        // same way the tvOS heroes already do.
        for target in [item, watchlistSubject, rootItem] {
            for action in actionHandler.actions(for: target, context: .none)
                where offersAction(action) && seen.insert(action).inserted {
                entries.append(ActionEntry(action: action, target: target))
            }
        }
        return entries
    }

    /// The show an episode hero's watchlist gesture acts on.
    ///
    /// ``MediaItem/watchlistSubject`` can only synthesize a bare `id` + `title`
    /// stub, because an episode payload carries the episode's own external ids and
    /// not its show's. On a SERIES page the real, fully-identified show is already
    /// in hand as `rootItem`, so it is used instead — a mutation carrying provider
    /// ids resolves on its own rather than depending on a warm identity index.
    private var watchlistSubject: MediaItem {
        let subject = item.watchlistSubject
        guard subject.id != item.id, subject.id == rootItem.id else { return subject }
        return rootItem
    }

    /// this page can't otherwise reach, and only when something can route it.
    private func offersAction(_ action: MediaItemAction) -> Bool {
        guard action.isNavigation else { return true }
        return offersParentNavigation && !action.navigatesToSelf && navigator != nil
    }

    private func perform(_ entry: ActionEntry) {
        if entry.action.isNavigation {
            if let navigator, let target = entry.target.navigationTarget(for: entry.action) {
                navigator(target)
            }
        } else {
            actionHandler.perform(entry.action, on: entry.target, context: .none)
        }
    }

    private var primaryActions: [ActionEntry] {
        actions.filter(\.action.isPrimaryDetailAction)
    }

    private var contextActions: [ActionEntry] {
        actions.filter {
            !$0.action.isPrimaryDetailAction && $0.id != parentNavigationEntry?.id
        }
    }

    /// The navigation action shown as its own button in the action row, so an
    /// episode page has a *visible* way back to its show rather than one buried
    /// in a long-press menu.
    private var parentNavigationEntry: ActionEntry? {
        actions.first { $0.action.isNavigation && !$0.action.navigatesToSelf }
    }

    private var hasSourceVersionOptions: Bool {
        sources.count > 1 || versions.count > 1
    }

    /// The episode's own 16:9 still, shown above its details on an episode page.
    /// Same artwork chain and spoiler policy as the episode cards.
    private var episodeStill: some View {
        FallbackAsyncImage(
            references: item.artworkReferences(for: .episodeThumbnail),
            variant: .landscapeCard,
            asyncFallbackURL: { await ArtworkRouter.shared.artworkURL(.thumbnail, for: item) }
        ) {
            MediaArtworkPlaceholder()
        }
        .blur(radius: appModel.settings.spoilers.settings.shouldHideThumbnail(for: item) ? 24 : 0)
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: style == .compactPortrait ? .infinity : 560)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }

    var body: some View {
        VStack(
            alignment: style == .compactPortrait ? .center : .leading,
            spacing: 12
        ) {
            if presentsEpisodeStill {
                episodeStill
            }
            PlozziOSHeroMetadata(
                presentation: presentation,
                style: style,
                mode: .detail,
                fallbackPresentation: fallbackPresentation,
                technicalBadgesOverride: playableItem?.technicalBadges,
                hidesRatings: appModel.settings.spoilers.settings
                    .shouldHideRatings(for: item),
                seriesBreadcrumb: presentsEpisodeStill ? item.parentTitle : nil,
                onTapBreadcrumb: parentNavigationEntry.map { entry in
                    { perform(entry) }
                },
                subjectTitle: presentsEpisodeStill ? item.title : nil,
                scheduleLine: scheduleLine
            )

            // Progressive overflow: try every inline layout from "all buttons
            // inline" down to "everything in the … menu", collapsing ONE action
            // at a time (least-important first). ViewThatFits picks the first
            // candidate that fits the hero's width, so actions only fold into "…"
            // when they'd otherwise wrap — and the same page always lays out the
            // same way for a given width.
            ViewThatFits(in: .horizontal) {
                // Widest first: everything inline with Trailer labelled, then the
                // same row with Trailer reduced to its glyph, and only then start
                // folding actions into "…".
                actionRow(collapsing: 0, labelledTrailer: true, resume: .full)
                ForEach(0...orderedInlineExtras.count, id: \.self) { collapseCount in
                    actionRow(
                        collapsing: collapseCount,
                        labelledTrailer: false,
                        resume: .full
                    )
                }
                // Every action is already in "…" by here, so the only thing left
                // to give is the Play button's resume detail. Without these the
                // narrowest candidate could still be wider than the hero — a
                // long "Resume S12, E7 • 43m" overflowed the text column and
                // dragged the whole hero off to one side.
                actionRow(
                    collapsing: orderedInlineExtras.count,
                    labelledTrailer: false,
                    resume: .seasonEpisodeOnly
                )
                actionRow(
                    collapsing: orderedInlineExtras.count,
                    labelledTrailer: false,
                    resume: .hidden
                )
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
        // Keyed on version too: switching version must re-check whether THAT
        // file is downloaded, not leave the button showing the old answer.
        .task(id: "\(downloadItem?.id ?? "")|\(downloadItem?.selectedVersionID ?? "")") {
            guard let downloadItem else {
                downloadRecord = nil
                return
            }
            downloadRecord = await appModel.downloads
                .record(forSelectedVersionOf: downloadItem)
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
            Text(verbatim: downloadError ?? "")
        }
    }

    /// A secondary hero action that can either sit inline as its own button or
    /// fold into the "…" overflow menu. Ordered most-important-first in
    /// `orderedInlineExtras`; the progressive layout collapses from the tail, so
    /// the least-used action is the first to move into "…".
    private enum InlineExtra: Identifiable {
        case primary(ActionEntry)
        case download
        case trailer

        var id: String {
            switch self {
            case .primary(let entry): return "media.\(entry.action.rawValue)"
            case .download: return "download"
            case .trailer: return "trailer"
            }
        }
    }

    /// Collapsible inline actions in **display** order. Play + Request are
    /// structural and always stay inline, so they're not listed here.
    ///
    /// Display order and fold order are deliberately separate — see `foldRank`.
    /// The trailer reads as part of the play affordance so it sits beside Play,
    /// yet it must survive longest, and those two facts pull in opposite
    /// directions if one list has to express both.
    private var orderedInlineExtras: [InlineExtra] {
        var extras: [InlineExtra] = []
        // Next to Play: on a title you don't have, the trailer and Request are
        // the only two things you can actually do.
        if trailerItem != nil, onPlayTrailer != nil {
            extras.append(.trailer)
        }
        extras.append(contentsOf: primaryActions.map { InlineExtra.primary($0) })
        // On an episode page the breadcrumb above the title carries this, so it
        // isn't repeated as a button in a row of watch-state actions.
        if !presentsEpisodeStill, let parentNavigationEntry {
            extras.append(.primary(parentNavigationEntry))
        }
        if downloadItem != nil {
            extras.append(.download)
        }
        return extras
    }

    /// Fold priority, lowest folds into "…" first. The power-user Download goes
    /// before everyday watch-state actions, and the trailer is the last to leave
    /// the row. It sheds its label first (see `actionRow`), which usually buys
    /// enough width that it never has to leave at all.
    private func foldRank(_ extra: InlineExtra) -> Int {
        switch extra {
        case .download: return 0
        case .primary(let entry):
            return entry.action.isNavigation ? 1 : 2
        case .trailer: return 3
        }
    }

    /// One candidate row that keeps the highest-priority extras inline and folds
    /// the last `collapseCount` of them into the "…" menu. ViewThatFits chooses the
    /// widest candidate (fewest collapsed) that still fits the hero width.
    private func actionRow(
        collapsing collapseCount: Int,
        labelledTrailer: Bool,
        resume: PlayResumeButtonLabel.ResumeTrailingStyle
    ) -> some View {
        let extras = orderedInlineExtras
        // Fold by priority, then render what survives in display order, so the
        // row never reshuffles as it narrows — buttons only disappear.
        let doomed = extras
            .enumerated()
            .sorted {
                let left = foldRank($0.element), right = foldRank($1.element)
                return left == right ? $0.offset < $1.offset : left < right
            }
            .prefix(max(0, collapseCount))
        let doomedOffsets = Set(doomed.map(\.offset))
        let inline = extras.enumerated()
            .filter { !doomedOffsets.contains($0.offset) }
            .map(\.element)
        let collapsed = doomed.map(\.element)
        let menu = menuActions(collapsing: collapsed)
        return HStack(spacing: 12) {
            playActionButton(resume: resume)
            heroRequestButton
            ForEach(inline) { extra in
                inlineExtraButton(extra, labelled: labelledTrailer)
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
    private func inlineExtraButton(
        _ extra: InlineExtra,
        labelled labelledTrailer: Bool
    ) -> some View {
        switch extra {
        case .primary(let entry):
            primaryActionButton(entry)
        case .download:
            downloadActionButton
        case .trailer:
            trailerActionButton(labelled: labelledTrailer)
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

    /// `labelled` false renders the glyph alone, which is about a third of the
    /// width. Tried before any action is pushed into "…", because a recognisable
    /// icon in the row beats a full word hidden in a menu.
    @ViewBuilder
    private func trailerActionButton(labelled: Bool) -> some View {
        if let trailerItem, let onPlayTrailer {
            Button {
                onPlayTrailer(trailerItem)
            } label: {
                if labelled {
                    Label("Trailer", systemImage: "film.fill")
                } else {
                    Image(systemName: "film.fill")
                        .font(.headline)
                }
            }
            // Without a label this is a glyph like the watchlist and download
            // buttons beside it, so it takes their circle. A capsule around a
            // lone icon read as a different kind of control.
            .buttonStyle(
                PlozziOSHeroActionButtonStyle(
                    kind: .secondary,
                    circular: !labelled
                )
            )
            .accessibilityLabel("Trailer")
        }
    }


    @ViewBuilder
    private func playActionButton(
        resume: PlayResumeButtonLabel.ResumeTrailingStyle = .full
    ) -> some View {
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
                    capsuleWidth: 60,
                    resumeTrailingStyle: resume
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
        var result = inlineActionEntries.map { entry in
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
        // So a collapsed Trailer is still reachable rather than simply gone.
        if trailerItem != nil, onPlayTrailer != nil {
            result.append(PlaybackSourceMenuAction(
                id: "trailer",
                title: "Trailer",
                systemImage: "film.fill"
            ))
        }
        return result
    }

    private func performCompactPanelAction(_ id: String) {
        if id == "download" {
            Task { await performDownloadAction() }
            return
        }
        if id == "trailer" {
            if let trailerItem, let onPlayTrailer { onPlayTrailer(trailerItem) }
            return
        }
        guard id.hasPrefix("media."),
              let entry = inlineActionEntries.first(where: {
                  "media.\($0.action.rawValue)" == id
              }) else {
            return
        }
        perform(entry)
    }

    /// Every entry that can appear inline, in the same order — so a collapsed
    /// one keeps its title/symbol and stays actionable from the "…" menu.
    private var inlineActionEntries: [ActionEntry] {
        primaryActions + (parentNavigationEntry.map { [$0] } ?? [])
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
                perform(entry)
            }
            .accessibilityLabel(entry.action.title)
            .accessibilityValue(
                // Verbatim: "no accessibility value" is the absence of copy, not
                // a string to translate. `Text("")` made the empty string a
                // catalog key that every language then had to "translate".
                entry.action.accessibilityState.map(Text.init) ?? Text(verbatim: "")
            )
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
                    versionTitleText(version.displayLabel)
                        .tag(version.id)
                }
            } label: {
                Label {
                    versionTitleText(selectedVersion.displayLabel)
                } icon: {
                    Image(systemName: "film.stack")
                }
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

    /// Renders a `MediaVersion` title: the joined technical facts (or provider
    /// name) verbatim when known, otherwise our own generic "Version" copy —
    /// kept as a real resource here rather than baked into a `String` so it
    /// translates like everything else.
    private func versionTitleText(_ displayLabel: String?) -> Text {
        if let displayLabel {
            return Text(verbatim: displayLabel)
        }
        return Text("Version", comment: "Generic label for a playback version/source with no distinguishing facts (resolution, edition, etc.) known.")
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

    /// Reuses `MediaItemAction`'s labels rather than repeating them: these were
    /// four duplicate literals of the same copy, which meant a wording change had
    /// to be made twice and — once localized — would have produced two catalog
    /// entries translators had to keep in sync by hand.
    private var downloadActionTitle: LocalizedStringResource {
        switch currentDownloadRecord?.status {
        case .queued, .downloading:
            return MediaItemAction.pauseDownload.title
        case .paused, .failed:
            return MediaItemAction.resumeDownload.title
        case .completed:
            return MediaItemAction.removeDownload.title
        case nil:
            return MediaItemAction.startDownload.title
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
    /// The owning show's name, shown as a breadcrumb link above an episode's own
    /// title in place of the show wordmark. `nil` on every other hero.
    var seriesBreadcrumb: String? = nil
    var onTapBreadcrumb: (() -> Void)? = nil
    /// The subject's own title, when it differs from `presentation.title`.
    var subjectTitle: String? = nil
    /// The air-schedule badge above the title ("New episode every Wednesday"), or
    /// `nil` when there is nothing truthful to say. Matches tvOS.
    var scheduleLine: LocalizedStringResource? = nil

    var body: some View {
        VStack(
            alignment: style == .compactPortrait ? .center : .leading,
            spacing: 9
        ) {
            if let seriesBreadcrumb {
                // The episode is this page's subject, so the show is context
                // rather than identity — and naming it says both where you are
                // and that you can leave. See `DetailHeroView` on tvOS.
                Button {
                    onTapBreadcrumb?()
                } label: {
                    HStack(spacing: 4) {
                        Text(seriesBreadcrumb)
                            .lineLimit(1)
                        Image(systemName: "chevron.forward")
                            .font(.subheadline.weight(.semibold))
                    }
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .disabled(onTapBreadcrumb == nil)
                .accessibilityLabel(Text("Go to \(seriesBreadcrumb)"))

                // `presentation.title` resolves an episode to its *show's* name,
                // which is right when a series hero fronts an episode but wrong
                // here: the breadcrumb above already names the show.
                Text(subjectTitle ?? presentation.title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            } else {
                if let scheduleLine {
                    scheduleBadge(scheduleLine)
                }
                let logoBox = PlozziOSPageLayout.heroLogoBox(for: style)
                HeroLogoArtwork(
                    references: presentation.logoReferences,
                    maxWidth: logoBox.width,
                    maxHeight: logoBox.height,
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
            }

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
                    // Same 60% tier as tvOS.
                    .plozzForeground(.secondary)
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
                        // Full strength, matching tvOS: these sit in a row with
                        // the ratings and capability chips, so a dimmer tier read
                        // as faded beside them.
                        Text(factComponents.joined(separator: "  ·  "))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.primaryText)
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

    /// The air-schedule badge. Same shape and copy as the tvOS hero so a series
    /// reads identically on both platforms, sized down for a phone.
    @ViewBuilder
    private func scheduleBadge(_ text: LocalizedStringResource) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(palette.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background { shape.fill(.regularMaterial) }
            .overlay { shape.stroke(palette.primaryText.opacity(0.16), lineWidth: 1) }
            .accessibilityLabel(text)
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

    private func credit(_ label: LocalizedStringResource, values: [String]) -> some View {
        let capped = Array(values.prefix(3))
        return (
            Text(label)
                .foregroundStyle(palette.secondaryText)
            + Text(verbatim: " ")
            + Text(verbatim: capped.formatted())
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
    /// True while the hero is moving to a slide that isn't the selected one yet.
    /// `dwellStart` still belongs to the outgoing slide until the transition
    /// commits, so without this the incoming bar inherits its progress.
    var isTransitioning: Bool = false
    let trailerController: HeroTrailerController

    var body: some View {
        // Drawn in Core Animation. Both the gauge and the page morph are stated
        // once and interpolated by the render server, so they run at the
        // display's full rate without the app doing per-frame work — this row
        // used to redraw itself thirty times a second and cost a steady 7.2% CPU
        // on an iPhone with nothing else happening.
        HeroPagingDotsRepresentable(
            configuration: .init(
                count: itemIDs.count,
                activeIndex: selectedIndex,
                autoAdvance: autoAdvance,
                gaugeFraction: gaugeFraction,
                gaugeRemaining: gaugeRemaining,
                rampID: "\(selectedItemID ?? "-")|\(dwellStart.timeIntervalSinceReferenceDate)"
            ),
            tint: UIColor(palette.primaryText)
        )
        .frame(
            width: HeroPagingIndicatorMetrics.rowWidth(count: itemIDs.count),
            height: HeroPagingIndicatorMetrics.dotSize
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hero item")
        .accessibilityValue(accessibilityValue)
    }

    private var selectedIndex: Int {
        guard let selectedItemID,
              let index = itemIDs.firstIndex(of: selectedItemID) else {
            return 0
        }
        return index
    }

    /// Where the gauge stands, decided by the shared rules in `HeroGaugeState`
    /// so this shell cannot drift from tvOS.
    private var gauge: HeroGaugeState {
        let trailerIsShowing = selectedItemID.map(trailerController.isShowing) ?? false
        return HeroGaugeState.resolve(
            autoAdvance: autoAdvance,
            dwellStart: dwellStart,
            dwellDuration: Double(autoAdvanceSeconds),
            now: Date(),
            isTransitioning: isTransitioning,
            trailerElapsed: trailerIsShowing
                ? trailerController.player.currentTime().seconds
                : nil,
            trailerDuration: trailerIsShowing ? trailerController.duration : nil
        )
    }

    private var gaugeFraction: CGFloat { gauge.fraction }
    private var gaugeRemaining: TimeInterval? { gauge.remaining }

    private var accessibilityValue: Text {
        guard let selectedItemID,
              let index = itemIDs.firstIndex(of: selectedItemID) else {
            return Text(verbatim: "")
        }
        return Text("\(index + 1) of \(itemIDs.count)")
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

/// Reports the window's height, so a hero can be sized to the phone it is on
/// rather than to a constant. See ``EnvironmentValues/plozziOSHeroContainerHeight``.
///
/// A `GeometryReader` around the page would report the safe-area content height,
/// which is the wrong measurement (the hero starts under the status bar) and
/// would have to be corrected by adding the insets back — reading the window is
/// the same answer without the correction. Mirrors `PlozziOSWindowWidthReader`.
struct PlozziOSWindowHeightReader: UIViewRepresentable {
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
        private var lastHeight: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        func report() {
            guard let height = window?.bounds.height,
                  height > 0,
                  height != lastHeight,
                  let onChange else {
                return
            }
            lastHeight = height
            Task { @MainActor in
                onChange(height)
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
