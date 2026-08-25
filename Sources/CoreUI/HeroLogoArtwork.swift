#if canImport(SwiftUI)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

/// A colour sample of the hero artwork behind the logo: the mean colour of the
/// sampled region plus its luminance. Used to decide whether a logo needs a
/// legibility halo — the decision weighs both brightness *and* colour, so a
/// vibrant logo (e.g. a saturated red wordmark) isn't haloed just because its
/// luminance happens to sit near the backdrop's.
public struct HeroBackgroundSample: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let luminance: Double

    public init(red: Double, green: Double, blue: Double, luminance: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
    }
}

/// Controls whether a hero may replace its readable text title after asynchronous
/// logo work completes.
public enum HeroLogoPresentationPolicy: Sendable, Equatable {
    /// Show the logo whenever it finishes. Best for a detail page that does not
    /// transition between many titles in place.
    case whenReady
    /// Adopt the logo only if it is ready within the arrival window. A later result
    /// still warms the shared cache, but the current title remains visually stable.
    case onArrival(maximumWait: TimeInterval)

    func shouldAdopt(elapsed: TimeInterval) -> Bool {
        switch self {
        case .whenReady:
            return true
        case .onArrival(let maximumWait):
            return elapsed <= max(0, maximumWait)
        }
    }

    var animatesResolvedLogo: Bool {
        self == .whenReady
    }
}

/// Renders a show's stylized title/logo art for the detail hero, falling back to
/// a plain text title when no logo can be found.
///
/// Resolution order:
///   1. `primaryURL` — the provider's own `Logo` image (e.g. Jellyfin).
///   2. `asyncFallbackURL` — a TMDb logo lookup, used only when the provider has
///      no usable logo.
///   3. `textFallback` — the caller's styled title `Text`, shown immediately while
///      artwork resolves and retained when no logo can be found.
///
/// The logo is fit (never cropped) inside a `maxWidth` × `maxHeight` box and
/// defaults to leading alignment, while callers presenting a centered logo can
/// opt into `.center`. By default it crossfades over the readable title once
/// decoded; arrival-sensitive callers can suppress a late replacement.
/// Unlike poster art there is no aspect-ratio guard — logos are legitimately wide.
/// What a resolved logo turned out to look like, reported to hosts that adapt
/// their backdrop to it.
///
/// Both numbers come free from the pixel pass that already trims and tones every
/// logo (``PreparedLogo``), so a host can react to the actual artwork without
/// commissioning any analysis of its own.
public struct ResolvedLogoTone: Equatable, Sendable {
    /// Mean luminance of the logo's own ink, 0…1.
    public let luminance: Double
    /// Share of its bounding box the logo actually paints, 0…1.
    public let coverage: Double
    /// Mean colour of the ink, so a host can compare it to what sits behind —
    /// two things can share a luminance and still separate perfectly well by hue.
    public let red: Double
    public let green: Double
    public let blue: Double
    /// Share of the ink bright enough to carry its own contrast — a white keyline,
    /// a pale highlight. A logo with plenty of it reads on almost any picture,
    /// whatever its mean tone says.
    public let brightInk: Double

    public init(luminance: Double, coverage: Double, red: Double = 0, green: Double = 0, blue: Double = 0, brightInk: Double = 0) {
        self.luminance = luminance
        self.coverage = coverage
        self.red = red
        self.green = green
        self.blue = blue
        self.brightInk = brightInk
    }
}

/// Which contrast halo a logo gets.
public enum HeroLogoHaloStyle: Sendable {
    /// A dark shadow at hero strength.
    ///
    /// Never a light one. A white glow behind a dark logo was the old behaviour
    /// here, and it was the most conspicuous thing on the screen whenever it fired
    /// — it reads as an effect stuck on the artwork rather than as the logo
    /// sitting on it. A shadow reads as depth, which is what the logo is actually
    /// doing: sitting in front of a picture.
    ///
    /// Drawn only when the artwork behind has been sampled and found too close in
    /// tone to the ink (see ``HeroLogoAnalysis``); a surface that never samples
    /// cannot prove a logo is safe and so draws it always.
    case standard
    /// The same dark shadow, much softer.
    ///
    /// For a surface that lays an even dim over its own artwork
    /// (``ContinueWatchingCardShape/artworkDim``), so the halo is not carrying
    /// legibility on its own — it only has to keep the letterforms from touching
    /// the picture. At full strength it instead read as a hard outline, worst on
    /// pale artwork where a tight black edge has the most to contrast against.
    case gentle
}

public struct HeroLogoArtwork<TextFallback: View>: View {
    private let references: [ArtworkReference]
    private let asyncFallbackURL: (@Sendable () async -> URL?)?
    private let backgroundSample: (@Sendable () async -> HeroBackgroundSample?)?
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private let presentationPolicy: HeroLogoPresentationPolicy
    private let alignment: Alignment
    private let haloStyle: HeroLogoHaloStyle
    private let logoNeedsHelp: Double?
    private let onResolve: ((ResolvedLogoTone) -> Void)?
    private let textFallback: () -> TextFallback

    public init(
        primaryURL: URL?,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        backgroundSample: (@Sendable () async -> HeroBackgroundSample?)? = nil,
        maxWidth: CGFloat = 620,
        maxHeight: CGFloat = 200,
        presentationPolicy: HeroLogoPresentationPolicy = .whenReady,
        alignment: Alignment = .leading,
        haloStyle: HeroLogoHaloStyle = .standard,
        logoNeedsHelp: Double? = nil,
        onResolve: ((ResolvedLogoTone) -> Void)? = nil,
        @ViewBuilder textFallback: @escaping () -> TextFallback
    ) {
        self.references = primaryURL.map { [.remote($0)] } ?? []
        self.asyncFallbackURL = asyncFallbackURL
        self.backgroundSample = backgroundSample
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.presentationPolicy = presentationPolicy
        self.alignment = alignment
        self.haloStyle = haloStyle
        self.logoNeedsHelp = logoNeedsHelp
        self.onResolve = onResolve
        self.textFallback = textFallback
    }

    /// Reference-aware logo entry point. URL-only callers keep using the original
    /// initializer; direct-share logos use the shared decoded cache and ordered
    /// fallback loader without exposing a transport dependency to SwiftUI.
    public init(
        references: [ArtworkReference],
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        backgroundSample: (@Sendable () async -> HeroBackgroundSample?)? = nil,
        maxWidth: CGFloat = 620,
        maxHeight: CGFloat = 200,
        presentationPolicy: HeroLogoPresentationPolicy = .whenReady,
        alignment: Alignment = .leading,
        haloStyle: HeroLogoHaloStyle = .standard,
        logoNeedsHelp: Double? = nil,
        onResolve: ((ResolvedLogoTone) -> Void)? = nil,
        @ViewBuilder textFallback: @escaping () -> TextFallback
    ) {
        self.references = references
        self.asyncFallbackURL = asyncFallbackURL
        self.backgroundSample = backgroundSample
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.presentationPolicy = presentationPolicy
        self.alignment = alignment
        self.haloStyle = haloStyle
        self.logoNeedsHelp = logoNeedsHelp
        self.onResolve = onResolve
        self.textFallback = textFallback
    }

    public var body: some View {
        #if canImport(UIKit)
        LoadedLogo(
            references: references,
            asyncFallbackURL: asyncFallbackURL,
            backgroundSample: backgroundSample,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            presentationPolicy: presentationPolicy,
            alignment: alignment,
            haloStyle: haloStyle,
            logoNeedsHelp: logoNeedsHelp,
            onResolve: onResolve,
            textFallback: textFallback
        )
        #else
        textFallback()
        #endif
    }
}

/// Processed logos held for synchronous reuse, so a rebuilt view paints a warmed
/// logo on its FIRST frame.
///
/// `HeroLogoPipeline` is an actor, so reading it always costs a suspension — even
/// on a hit. That is one frame with no logo, which draws the styled title: the
/// text appearing *after* a logo had already loaded. The pipeline stays the
/// source of truth and does all the work; this only makes an already-resolved
/// answer readable without awaiting.
///
/// Main-actor isolated, so it needs no lock and can be read during `body`.
@MainActor
enum HeroLogoMemo {
    private static var entries: [String: ProcessedLogo] = [:]
    private static var order: [String] = []
    /// Enough for a hero carousel plus the pages reached from it. Evicting
    /// oldest-first costs one await on the next look, not a re-decode.
    private static let capacity = 60

    static func value(for key: String) -> ProcessedLogo? { entries[key] }

    static func store(_ value: ProcessedLogo, for key: String) {
        if entries[key] == nil {
            order.append(key)
            if order.count > capacity, let oldest = order.first {
                order.removeFirst()
                entries[oldest] = nil
            }
        }
        entries[key] = value
    }
}

#if canImport(UIKit)
private struct LoadedLogo<TextFallback: View>: View {
    let references: [ArtworkReference]
    let asyncFallbackURL: (@Sendable () async -> URL?)?
    let backgroundSample: (@Sendable () async -> HeroBackgroundSample?)?
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let presentationPolicy: HeroLogoPresentationPolicy
    let alignment: Alignment
    let haloStyle: HeroLogoHaloStyle
    let logoNeedsHelp: Double?
    let onResolve: ((ResolvedLogoTone) -> Void)?
    let textFallback: () -> TextFallback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var image: ProcessedLogo?
    /// The `taskKey` the current `image` was resolved for, so a re-resolve for the
    /// SAME subject can keep it on screen while a different subject clears it.
    @State private var resolvedKey: String?

    var body: some View {
        // Falls back to the synchronous memo, so a logo this view has already
        // resolved once paints on the FIRST frame of a rebuild. Without it every
        // rebuild drew the styled title for at least one frame, because the
        // pipeline is an actor and even a cache hit costs a suspension.
        let shown = image ?? HeroLogoMemo.value(for: taskKey)
        Group {
            if let processed = shown {
                logo(processed)
                    .transition(.opacity)
            } else {
                // A cache miss may include a network lookup plus decode/analysis.
                // Keep the title readable throughout; identity must never depend
                // on optional artwork finishing first.
                textFallback()
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion || !presentationPolicy.animatesResolvedLogo
                ? nil
                : .easeIn(duration: 0.25),
            value: shown != nil
        )
        .task(id: taskKey) { await resolve() }
    }

    /// The exact size a logo renders at inside the `maxWidth` × `maxHeight` box.
    ///
    /// `.resizable().aspectRatio(contentMode: .fit).frame(maxWidth:maxHeight:)` does
    /// **not** shrink the frame to the fitted artwork: a resizable image has no
    /// intrinsic size, so it accepts the full proposal and the frame stays the full
    /// max height with the artwork centred inside it. Measured on device: a
    /// 784 × 141 wordmark rendered ~111pt tall inside a frame reporting 200pt, so
    /// ~89pt of empty frame sat around it — and because the leftover depends on each
    /// logo's aspect ratio, the gap above and below the logo changed from title to
    /// title. Sizing the frame from the image's own ratio removes the slack.
    private func fittedSize(for processed: ProcessedLogo) -> CGSize {
        HeroLogoFit.fittedSize(
            for: processed.image.size,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            coverage: processed.coverage
        )
    }

    /// Renders the resolved logo. Most logos draw as-is with a contrast halo,
    /// applied *only* to logos that need it (`needsHalo`). Under
    /// ``HeroLogoHaloStyle/adaptive`` that's a soft light glow behind dark logos
    /// and a soft dark shadow behind light ones, used only when the measured
    /// logo/background contrast is low, so logos that already stand out stay
    /// clean; under ``HeroLogoHaloStyle/alwaysDark`` it is always the dark
    /// shadow.
    ///
    /// A *monochrome* logo (a single near-grayscale tone, e.g. an all-black or
    /// all-white wordmark) is instead recoloured to the foreground tone of the
    /// current colour scheme — white in dark mode, black in light mode — so a
    /// black wordmark on a dark hero flips to white and stays legible, matching how
    /// the rest of the UI adapts. Its alpha (the letter shapes) is preserved as a
    /// template mask, so only single-tone logos qualify (guarded in `finalize`),
    /// never multi-colour brand art. It needs no halo: it is recoloured to the
    /// scheme's foreground tone and the hero scrim is the scheme's background tone,
    /// so it is guaranteed to contrast with what sits behind it.
    @ViewBuilder
    private func logo(_ processed: ProcessedLogo) -> some View {
        let fitted = fittedSize(for: processed)
        if processed.isMonochrome {
            let tintLight = colorScheme == .dark   // dark mode → light (white) logo
            Image(uiImage: processed.image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: fitted.width, height: fitted.height)
                .frame(maxWidth: maxWidth, alignment: alignment)
                .foregroundStyle(tintLight ? Color.white : Color.black)
        } else {
            Image(uiImage: processed.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: fitted.width, height: fitted.height)
                .frame(maxWidth: maxWidth, alignment: alignment)
                .modifier(LogoToneLift(
                    needsHelp: logoNeedsHelp,
                    luminance: processed.luminance,
                    active: haloStyle == .gentle
                ))
                .modifier(LogoLegibilityHalo(
                    active: processed.needsHalo,
                    scale: LogoLegibilityHalo.scale(forLogoHeight: fitted.height),
                    isGentle: haloStyle == .gentle
                ))
        }
    }

    /// Re-run resolution whenever the candidate sources change.
    private var taskKey: String {
        (references.map(\.privacySafeIdentity) + [asyncFallbackURL == nil ? "0" : "1"])
            .joined(separator: "|")
    }

    private func resolve() async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        // Deliberately NOT cleared here.
        //
        // Blanking first meant every re-resolve dropped a logo that was already on
        // screen back to the styled title, and then restored it — the text
        // reappearing *after* the logo had loaded. A re-resolve is common: the
        // reference list changes as a title is enriched, and a hero carousel
        // rebuilds its slides as it pages.
        //
        // Keeping the old logo is safe because a logo is only ever REPLACED by one
        // that has finished decoding, so there is no window where the wrong art is
        // shown as final. The one case that must still clear is a change of
        // subject: `.task(id:)` re-runs when `taskKey` changes, and a slide reused
        // for a different title must not keep the previous show's wordmark.
        if resolvedKey != taskKey { image = nil }
        let key = taskKey
        // `HeroLogoPipeline` caches the processed result by URL and runs the heavy
        // pixel work off the main actor, so re-appears / scheme changes / fast
        // scrolling reuse the prepared logo instead of reprocessing it.
        guard let prepared = await loadPreparedHeroLogo(
            references: references,
            asyncFallbackURL: asyncFallbackURL,
            priority: .userInitiated
        ) else { return }
        guard !Task.isCancelled else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        guard presentationPolicy.shouldAdopt(elapsed: elapsed) else { return }
        resolvedKey = key

        // Draw the logo the moment it is decoded, BEFORE the backdrop is sampled.
        //
        // The sample is a second image fetched and analysed, and waiting on it
        // held a logo that was already in hand — so the styled title sat on screen
        // for the duration and was then replaced, which reads as a flash rather
        // than as loading. Nothing about the halo decision is worth that: the
        // logo is the content, the halo is a refinement to it.
        //
        // Unmeasured means no halo *when a measurement is actually coming*. A
        // caller with no sampler at all (a rail of cards, where per-card analysis
        // would be one image pass per card while scrolling) keeps the conservative
        // always-on halo, because for that caller "unmeasured" is permanent rather
        // than momentary.
        let awaitsSample = backgroundSample != nil
        adopt(HeroLogoAnalysis.analyze(
            prepared,
            backgroundSample: nil,
            halosWhenUnmeasured: !awaitsSample
        ))
        guard awaitsSample else { return }

        // Then refine in place. A halo appearing a beat late is a soft shadow
        // fading in under artwork the viewer is already reading; a logo appearing
        // a beat late is the title of the show changing shape. A sample that fails
        // to resolve falls back to the halo, since an unmeasured logo still cannot
        // be proven safe.
        let sample = await backgroundSample?()
        guard !Task.isCancelled else { return }
        adopt(HeroLogoAnalysis.analyze(prepared, backgroundSample: sample))
    }

    private func adopt(_ processed: ProcessedLogo) {
        image = processed
        HeroLogoMemo.store(processed, for: taskKey)
        onResolve?(ResolvedLogoTone(
            luminance: processed.luminance,
            coverage: processed.coverage,
            red: processed.red,
            green: processed.green,
            blue: processed.blue,
            brightInk: processed.brightInk
        ))
    }
}

/// Shared logo legibility analysis, so the SwiftUI ``HeroLogoArtwork`` and the
/// imperative UIKit hero foreground (`HeroForegroundUIView`) treat logos
/// identically: the same single-tone-wordmark detection (recoloured to the
/// scheme foreground) and the same adaptive contrast-halo decision. Before this
/// was shared, the UIKit hero drew the *raw* cached logo — so a monochrome
/// wordmark never flipped colour in light mode and low-contrast logos got no
/// halo, unlike the detail hero.
enum HeroLogoAnalysis {
    /// Logo/background luminance gap (0…1) below which the logo no longer
    /// separates by brightness alone. Tuned for a "clean" lean.
    static let haloLuminanceThreshold = 0.26

    /// Perceptual logo/background colour distance (0…~3, see `perceptualDistance`)
    /// below which the logo no longer separates by colour either. Above it a
    /// vibrant logo reads clearly against the backdrop and needs no halo.
    static let haloColorThreshold = 0.40

    /// Combines the prepared logo with an optional colour sample of the background
    /// to decide the monochrome recolour + halo. With no sample we keep the halo
    /// on, since we can't prove the logo is safe without it.
    ///
    /// A logo is legible when it separates from the artwork behind it by *either*
    /// brightness or colour, so the halo is reserved for the cases where it does
    /// neither. A logo is "monochrome" when its visible pixels are a single
    /// near-grayscale tone at one luminance extreme — an all-black or all-white
    /// wordmark that can be safely recoloured to the scheme foreground via its
    /// alpha mask (the coverage guard excludes never-stripped solid rectangles).
    static func analyze(
        _ prepared: PreparedLogo,
        backgroundSample: HeroBackgroundSample?,
        halosWhenUnmeasured: Bool = true
    ) -> ProcessedLogo {
        let isDark = prepared.luminance < 0.5
        let chroma = max(prepared.red, prepared.green, prepared.blue)
            - min(prepared.red, prepared.green, prepared.blue)
        let isMonochrome = prepared.coverage < 0.85
            && chroma < 0.10
            && (prepared.luminance < 0.22 || prepared.luminance > 0.85)

        var needsHalo = halosWhenUnmeasured
        if let bg = backgroundSample {
            let lumaGap = abs(prepared.luminance - bg.luminance)
            let colorGap = perceptualDistance(
                r1: prepared.red, g1: prepared.green, b1: prepared.blue,
                r2: bg.red, g2: bg.green, b2: bg.blue
            )
            needsHalo = lumaGap < haloLuminanceThreshold && colorGap < haloColorThreshold
        }
        return ProcessedLogo(
            image: prepared.image,
            isDark: isDark,
            needsHalo: needsHalo,
            isMonochrome: isMonochrome,
            coverage: prepared.coverage,
            luminance: prepared.luminance,
            red: prepared.red,
            green: prepared.green,
            blue: prepared.blue,
            brightInk: prepared.brightInk
        )
    }

    /// Weighted ("redmean") RGB distance — a cheap approximation of perceived
    /// colour difference that tracks the eye far better than raw Euclidean RGB.
    /// Inputs are 0…1 per channel; the result ranges 0 (identical) to ~3
    /// (black↔white).
    static func perceptualDistance(
        r1: Double, g1: Double, b1: Double,
        r2: Double, g2: Double, b2: Double
    ) -> Double {
        let rMean = (r1 + r2) / 2
        let dr = r1 - r2
        let dg = g1 - g2
        let db = b1 - b2
        return ((2 + rMean) * dr * dr + 4 * dg * dg + (3 - rMean) * db * db).squareRoot()
    }
}

#if canImport(UIKit)
/// A hero logo rendered for the imperative UIKit foreground (`HeroForegroundUIView`):
/// the prepared (background-stripped, trimmed) image plus the same legibility
/// decisions the SwiftUI hero makes. The caller applies them with UIKit
/// primitives — a monochrome logo as a `.alwaysTemplate` image tinted to the
/// scheme foreground, and a layer-shadow halo when `needsHalo` — so both hero
/// surfaces render logos identically.
///
/// `@unchecked Sendable`: an immutable value whose only reference type is a
/// `UIImage` created once and thereafter read-only.
public struct HeroUIKitLogo: @unchecked Sendable {
    public let image: UIImage
    /// Single-tone wordmark: draw as a template image tinted to the scheme
    /// foreground (white in dark mode, black in light mode).
    public let isMonochrome: Bool
    /// Whether a legibility halo is needed (ignored for monochrome logos, which
    /// contrast against the scheme-tone scrim by construction).
    public let needsHalo: Bool
    /// Whether the logo reads dark (picks the halo colour: light glow for a dark
    /// logo, dark glow for a light one).
    public let isDark: Bool
    /// Measured ink coverage, so this hero sizes the logo through the same
    /// ink-corrected fit the SwiftUI one uses and a show's wordmark carries the
    /// same weight on both screens — see ``HeroLogoFit/inkScale(coverage:)``.
    public let coverage: Double
}

/// Loads and analyses a hero logo through the exact same shared pipeline the
/// SwiftUI ``HeroLogoArtwork`` uses (`HeroLogoPipeline` prepare + cache, then
/// ``HeroLogoAnalysis``), so the imperative UIKit hero can recolour/halo logos
/// identically instead of drawing the raw cached image.
public enum HeroUIKitLogoRenderer {
    public static func render(
        references: [ArtworkReference],
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        backgroundSample: (@Sendable () async -> HeroBackgroundSample?)? = nil,
        priority: TaskPriority = .userInitiated
    ) async -> HeroUIKitLogo? {
        guard let prepared = await loadPreparedHeroLogo(
            references: references,
            asyncFallbackURL: asyncFallbackURL,
            priority: priority
        ) else { return nil }
        let processed = HeroLogoAnalysis.analyze(prepared, backgroundSample: await backgroundSample?())
        return HeroUIKitLogo(
            image: processed.image,
            isMonochrome: processed.isMonochrome,
            needsHalo: processed.needsHalo,
            isDark: processed.isDark,
            coverage: processed.coverage
        )
    }

    public static func render(
        primaryURL: URL?,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        backgroundSample: (@Sendable () async -> HeroBackgroundSample?)? = nil,
        priority: TaskPriority = .userInitiated
    ) async -> HeroUIKitLogo? {
        await render(
            references: primaryURL.map { [.remote($0)] } ?? [],
            asyncFallbackURL: asyncFallbackURL,
            backgroundSample: backgroundSample,
            priority: priority
        )
    }
}
#endif

/// Opportunistically prepares logo artwork before a hero slide becomes visible.
/// The shared pipeline de-duplicates this work with any foreground request.
public enum HeroLogoPreloader {
    public static func warm(primaryURL: URL?) async {
        guard let primaryURL else { return }
        _ = await loadPreparedHeroLogo(
           references: [.remote(primaryURL)],
            asyncFallbackURL: nil,
            priority: .utility
        )
    }

    public static func warm(references: [ArtworkReference]) async {
       _ = await loadPreparedHeroLogo(
           references: references,
           asyncFallbackURL: nil,
           priority: .utility
       )
    }
}

private func loadPreparedHeroLogo(
    references: [ArtworkReference],
    asyncFallbackURL: (@Sendable () async -> URL?)?,
    priority: TaskPriority
) async -> PreparedLogo? {
    guard !Task.isCancelled else { return nil }
    for reference in references {
       guard !Task.isCancelled else { return nil }
       if let prepared = await HeroLogoPipeline.shared.preparedLogo(
           for: reference,
           priority: priority
       ) {
           return prepared
       }
    }
    guard !Task.isCancelled,
          let asyncFallbackURL,
          let url = await asyncFallbackURL(),
          !Task.isCancelled
    else {
        return nil
    }
    return await HeroLogoPipeline.shared.preparedLogo(for: .remote(url), priority: priority)
}

/// A logo after background removal/trim, carrying the mean luminance *and* mean
/// colour of its visible pixels (plus how much of the frame it covers) so the
/// caller can decide whether a contrast halo is needed and whether the logo is a
/// single-tone wordmark safe to recolour.
///
/// Marked `@unchecked Sendable`: it is an immutable value whose only reference
/// type is a `UIImage` that is created once and thereafter read-only, so it is
/// safe to cache and hand across the actor boundary in `HeroLogoPipeline`.
struct PreparedLogo: @unchecked Sendable {
    let image: UIImage
    let luminance: Double
    let red: Double
    let green: Double
    let blue: Double
    /// Alpha-weighted fraction of the whole frame that is opaque (0…1). Low for a
    /// normal wordmark surrounded by transparency; ~1 for a logo whose background
    /// was never removed (a near-solid rectangle), which must not be recoloured.
    let coverage: Double
    /// Share of the logo's ink that is bright enough to read against almost
    /// anything (0…1) — a white keyline, a pale highlight. Distinct from
    /// ``luminance``, which is the mean and so misses exactly this.
    let brightInk: Double

    /// Luminance above which ink counts as carrying its own contrast.
    static let brightInkLuminance = 0.72

    init(
        image: UIImage,
        luminance: Double,
        red: Double = 0,
        green: Double = 0,
        blue: Double = 0,
        coverage: Double = 1.0,
        brightInk: Double = 0
    ) {
        self.image = image
        self.luminance = luminance
        self.red = red
        self.green = green
        self.blue = blue
        self.coverage = coverage
        self.brightInk = brightInk
    }
}

/// A fully-resolved hero logo ready to render: the processed image, whether it
/// reads as dark (halo colour), whether the halo should be shown at all, and
/// whether it is a single-tone wordmark (recoloured to the scheme's foreground,
/// in which case it needs no halo).
struct ProcessedLogo {
    let image: UIImage
    let isDark: Bool
    let needsHalo: Bool
    let isMonochrome: Bool
    /// Carried through from ``PreparedLogo/coverage`` so the fit can correct a
    /// logo's drawn size for how much ink it actually carries — see
    /// ``HeroLogoFit/inkScale(coverage:)``.
    let coverage: Double
    /// The logo's own mean tone, reported to hosts that adapt their backdrop to
    /// it — see ``HeroLogoArtwork``'s `onResolve`.
    let luminance: Double
    let red: Double
    let green: Double
    let blue: Double
    let brightInk: Double
}

/// Decodes, background-strips, trims, and measures hero logos, caching the
/// finished `PreparedLogo` by source URL.
///
/// Why this exists: the per-pixel work in `preparedAsHeroLogo()` is O(width ×
/// height) and a detail hero can appear, re-render on a colour-scheme change, or
/// scroll past many times. Without a cache the same logo is reprocessed on every
/// appearance. This actor:
///   * returns a cached `PreparedLogo` immediately on a hit (no pixel work),
///   * coalesces concurrent requests for the same URL onto one in-flight task
///     (fast scrolling can't kick off duplicate work), and
///   * runs the decode + pixel passes on a detached task so the main actor is
///     never blocked.
/// A small LRU bound keeps memory flat across a large library.
actor HeroLogoPipeline {
    static let shared = HeroLogoPipeline()

    /// Warms the cache for a card that has not scrolled into view yet.
    ///
    /// A logo resolves asynchronously, so a card that appears before its logo does
    /// shows the styled title first and swaps once the artwork lands. On a row the
    /// viewer is scrolling that swap is visible — the card changes under them,
    /// which is exactly what a rail should never do. Artwork was already warmed
    /// ahead of the scroll; this does the same for the logo (and, because the
    /// prepared result carries the tone the card's backdrop reacts to, for the
    /// dim as well) so both are resident before the card is reached.
    ///
    /// Fire-and-forget and at background priority: it must never compete with the
    /// cards actually on screen. Requests coalesce and results are cached, so a
    /// rail scrolled back and forth pays once.
    nonisolated func prefetch(references: [ArtworkReference]) {
        guard let first = references.first else { return }
        Task.detached(priority: .background) {
            _ = await self.preparedLogo(for: first, priority: .background)
        }
    }

    private struct CacheEntry {
        let logo: PreparedLogo
        let reference: ArtworkReference
    }

    private struct NetworkToken: Equatable {
        let accountGeneration: UInt64
        let revisionGeneration: UInt64
    }

    private struct Running {
        let id: UUID
        let task: Task<PreparedLogo?, Never>
        let reference: ArtworkReference
        let token: NetworkToken?
    }

    private var cache: [String: CacheEntry] = [:]
    private var order: [String] = []
    private var inFlight: [String: Running] = [:]
    private var accountGenerations: [String: UInt64] = [:]
    private var revisionGenerations: [String: UInt64] = [:]
    private let capacity = 48

    func preparedLogo(
        for reference: ArtworkReference,
        priority: TaskPriority = .userInitiated
    ) async -> PreparedLogo? {
        let key = reference.privacySafeIdentity
        if let hit = cache[key] {
            promote(key)
            return hit.logo
        }
        if let running = inFlight[key] {
            return await running.task.value
        }
        let token = networkToken(for: reference)
        let id = UUID()
        let task = Task.detached(priority: priority) {
            await HeroLogoPipeline.fetchAndPrepare(reference)
        }
        inFlight[key] = Running(id: id, task: task, reference: reference, token: token)
        let result = await task.value
        if inFlight[key]?.id == id {
            inFlight.removeValue(forKey: key)
        }
        guard token == networkToken(for: reference) else { return nil }
        if let result {
            store(result, reference: reference, key: key)
        }
        return result
    }

    func purgeNetworkArtwork(
        accountID: String,
        credentialRevision: CredentialRevision?
    ) async {
        if let credentialRevision {
            revisionGenerations[revisionKey(accountID, credentialRevision), default: 0] &+= 1
        } else {
            accountGenerations[accountID, default: 0] &+= 1
        }
        let cachedKeys = cache.compactMap { key, entry in
            matches(
                entry.reference,
                accountID: accountID,
                credentialRevision: credentialRevision
            ) ? key : nil
        }
        for key in cachedKeys {
            cache.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
        let running = inFlight.compactMap { key, running in
            matches(
                running.reference,
                accountID: accountID,
                credentialRevision: credentialRevision
            ) ? (key, running) : nil
        }
        for (key, running) in running {
            inFlight.removeValue(forKey: key)
            running.task.cancel()
        }
        for (_, running) in running {
            _ = await running.task.value
        }
    }

    private func store(_ value: PreparedLogo, reference: ArtworkReference, key: String) {
        if cache[key] == nil { order.append(key) }
        cache[key] = CacheEntry(logo: value, reference: reference)
        while order.count > capacity {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func promote(_ key: String) {
        guard let idx = order.firstIndex(of: key) else { return }
        order.remove(at: idx)
        order.append(key)
    }

    private func networkToken(for reference: ArtworkReference) -> NetworkToken? {
        guard case let .networkFile(network) = reference else { return nil }
        return NetworkToken(
            accountGeneration: accountGenerations[network.accountID, default: 0],
            revisionGeneration: revisionGenerations[
                revisionKey(network.accountID, network.credentialRevision),
                default: 0
            ]
        )
    }

    private func matches(
        _ reference: ArtworkReference,
        accountID: String,
        credentialRevision: CredentialRevision?
    ) -> Bool {
        guard case let .networkFile(network) = reference,
              network.accountID == accountID else { return false }
        return credentialRevision == nil || network.credentialRevision == credentialRevision
    }

    private func revisionKey(
        _ accountID: String,
        _ credentialRevision: CredentialRevision
    ) -> String {
        "\(accountID)|\(credentialRevision.rawValue.uuidString)"
    }

    private static func fetchAndPrepare(_ reference: ArtworkReference) async -> PreparedLogo? {
        switch reference {
        case .remote(let url):
            guard let (data, response) = try? await ArtworkSession.shared.data(from: url) else {
                return nil
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return decodeAndPrepare(data)
        case .networkFile:
            guard let image = await ArtworkImageCache.shared.image(
                for: reference,
                variant: .heroPreview
            ) else {
                return nil
            }
            return image.preparedAsHeroLogo()
        }
    }

    /// Downsample the logo to a hero-appropriate size before the halo/contrast
    /// analysis, so a large source PNG (some providers ship 1000px+ wordmarks)
    /// never inflates a full-size bitmap for a logo drawn at ~300–500pt. 900px is
    /// crisp at hero size on a 4K panel while a fraction of the memory. Alpha is
    /// preserved by the ImageIO thumbnail path; a decode failure falls back to a
    /// full decode so a logo never silently vanishes.
    private static func decodeAndPrepare(_ data: Data) -> PreparedLogo? {
        let image = ArtworkImageCache.downsample(data, maxPixelSize: 900) ?? UIImage(data: data)
        return image?.preparedAsHeroLogo()
    }
}

/// Wraps the logo in a soft, single-tone halo so it separates from the hero
/// regardless of the artwork behind it. Two stacked shadows build a stronger,
/// evenly-spread glow than one. `active == false` is a clean pass-through, so a
/// logo that already contrasts with its background renders with no halo at all.
///
/// The radii are proportional to the logo, not absolute. They were calibrated
/// against the hero's 200pt slot, and a shadow is a property of the thing casting
/// it: reused unscaled on a card — where the logo is nearer 30pt — a 14pt blur is
/// half the logo's height, and the "halo" closes over the glyphs instead of
/// sitting behind them. On an iPad Continue Watching card that read as a layer of
/// dirt on every logo: gold wordmarks came out brown, and the effect was most
/// obvious on exactly the bright logos that needed no help.
/// Lifts a **dark logo on a dark picture** toward legibility without bleaching it.
///
/// The card's other lever is dimming the artwork, and that only works in one
/// direction: it helps a logo that is brighter than its backdrop. When both are
/// dark there is nothing left to take — House of the Dragon's bronze serif over
/// near-black fire sits at a tenth of the card's brightness range with its
/// backdrop, and darkening that backdrop further buys nothing while draining the
/// picture. The only remaining lever is the logo itself.
///
/// Recolouring it white would work and is what the monochrome path already does
/// for single-tone wordmarks — but it throws away the thing that makes a logo
/// *that show's* logo, so it is reserved for art that was greyscale to begin
/// with. Instead this raises the logo's brightness and pushes its saturation up
/// to compensate: additive brightness alone drifts toward white, so restoring the
/// chroma it costs is what keeps a bronze wordmark bronze. Measured on House of
/// the Dragon's palette the ink goes from luminance 0.34 to 0.47 while its chroma
/// *rises* from 0.40 to 0.51 — brighter and more itself, not washed out.
struct LogoToneLift: ViewModifier {
    /// How badly this logo needs help, 0…1 — see
    /// ``ContinueWatchingCardShape/separation(logo:background:)``. `nil` while the
    /// artwork behind is still unmeasured, which means no lift: the difference
    /// between a logo that needs one and a logo that does not is precisely the
    /// thing that has not been measured yet.
    let needsHelp: Double?
    let luminance: Double
    let active: Bool

    /// Ceiling on the added brightness, and the cap that keeps even the worst case
    /// from washing the ink out.
    static let maximumLift: Double = 0.45
    static let liftCap: Double = 0.20
    /// Saturation restored per unit of brightness added. Tuned so the lift climbs
    /// in vividness rather than toward white.
    static let saturationPerLift: Double = 2.2

    /// The brightness to add for a logo in this much trouble at this tone.
    ///
    /// Two factors, and both matter. **Need** comes from the shared separation
    /// measure, not from the logo's tone: an earlier version lifted anything dark
    /// on a dark picture, which is the right instinct but the wrong test — it
    /// would have brightened Lilo & Stitch's red wordmark, which is dark by
    /// luminance and yet perfectly readable on open sky, while ignoring Boba
    /// Fett's metallic type, which is not dark at all and still disappears into
    /// its own warm scene.
    ///
    /// **Headroom** is how much brighter the ink can actually get. A near-white
    /// logo has nowhere to go and lifting it only greys the picture around it;
    /// a dark one has the whole range. This is what makes the lift and the dim
    /// complementary rather than redundant — the dim works by pulling the backdrop
    /// down and runs out when the backdrop is already black, exactly where a dark
    /// logo has the most room to be pulled up.
    static func lift(needsHelp: Double?, luminance: Double) -> Double {
        guard let needsHelp, needsHelp > 0 else { return 0 }
        let headroom = max(0, 1 - luminance)
        return min(liftCap, maximumLift * needsHelp * headroom)
    }

    func body(content: Content) -> some View {
        let lift = active ? Self.lift(needsHelp: needsHelp, luminance: luminance) : 0
        if lift <= 0.002 {
            content
        } else {
            content
                .brightness(lift)
                .saturation(1 + lift * Self.saturationPerLift)
        }
    }
}

struct LogoLegibilityHalo: ViewModifier {
    let active: Bool
    /// 1 at hero size, proportionally smaller for a card-sized logo.
    var scale: CGFloat = 1
    /// Whether the host already dims its artwork, so the halo only has to keep
    /// the letterforms off the picture rather than carry legibility itself.
    var isGentle: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    /// The hero logo slot the radii below were tuned against.
    private static let referenceHeight: CGFloat = 200

    /// Halo scale for a logo of `height` points. Floored rather than left linear:
    /// below about a quarter of hero size the shadow stops reading as depth and
    /// starts disappearing entirely, and a small logo on busy artwork still needs
    /// an edge.
    static func scale(forLogoHeight height: CGFloat) -> CGFloat {
        guard height > 0 else { return 1 }
        return min(1, max(0.25, height / referenceHeight))
    }

    func body(content: Content) -> some View {
        if !active {
            content
        } else if isGentle {
            // Barely a halo at all, and deliberately so: a halo is a visible thing
            // drawn around the letterforms, and past a certain strength it reads
            // as an outline stuck on the logo rather than as the logo sitting on
            // the picture. Legibility here is the *backdrop's* job — the host
            // deepens its dim for exactly the logos at risk of vanishing (see
            // ``ContinueWatchingCardShape/artworkDim(forLogoLuminance:)``), which
            // separates the two by darkening what is behind rather than by adding
            // anything in front. What is left for this to do is soften the edge
            // where ink meets picture, so it is wide, faint, and closer to a
            // shadow than a halo.
            content
                .shadow(color: .black.opacity(0.16), radius: 14 * scale)
                .shadow(color: .black.opacity(0.10), radius: 30 * scale)
        } else if colorScheme == .light {
            // Softer, lighter dark glow in light mode: the light-mode hero is
            // already bright, so a heavy black halo reads as a hard smudge. Lower
            // opacity + a wider radius keeps the logo legible with a gentle lift.
            content
                .shadow(color: .black.opacity(0.26), radius: 9 * scale)
                .shadow(color: .black.opacity(0.18), radius: 22 * scale)
        } else {
            // Softened from 0.55/0.45 at 5/14. The old pair was tuned as the
            // counterpart to a white glow that no longer exists, and read as a
            // dark rim once it was the only treatment; widening the radii and
            // dropping the opacity keeps the letterforms off the picture while
            // looking like depth rather than an edge.
            content
                .shadow(color: .black.opacity(0.42), radius: 8 * scale)
                .shadow(color: .black.opacity(0.30), radius: 20 * scale)
        }
    }
}

private extension UIImage {
    /// Prepares a raw logo image for the hero: strips a baked-in solid-colour
    /// background when present, trims transparent margins so logos align by their
    /// visible content, and measures the logo's luminance (used to pick and gate
    /// the contrast halo). Returns `nil` when nothing usable remains (no decodable
    /// image, or removal erased essentially everything).
    func preparedAsHeroLogo() -> PreparedLogo? {
        guard let cg = cgImage, cg.width > 0, cg.height > 0 else {
            return PreparedLogo(image: self, luminance: 0.0)
        }
        let width = cg.width
        let height = cg.height
        // Guard against pathologically large logos — the per-pixel passes below
        // are O(width*height); skip the heavy work and use the image as-is.
        if width * height > 8_000_000 {
            return PreparedLogo(image: self, luminance: 0.0)
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let success = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return PreparedLogo(image: self, luminance: 0.0) }

        // Identify an opaque background plate (a deliberate solid title-card box)
        // from the border ring; `nil` means the logo is genuinely transparent and
        // nothing is stripped.
        let plate = Self.detectBackgroundPlate(data, width: width, height: height, bytesPerRow: bytesPerRow)

        // Single fused pass: strip the plate (when present) *and* measure the
        // content bounds + tone of what survives, so the full image is touched
        // exactly once instead of in two separate O(width*height) passes.
        let stats = Self.stripPlateAndMeasure(
            &data, width: width, height: height, bytesPerRow: bytesPerRow, plate: plate
        )

        let weight = stats.weight
        let luminance = weight > 0 ? (stats.lumaSum / weight) : 0.0
        let meanR = weight > 0 ? (stats.rSum / weight) : 0.0
        let meanG = weight > 0 ? (stats.gSum / weight) : 0.0
        let meanB = weight > 0 ? (stats.bSum / weight) : 0.0

        // If background removal (or a fully transparent source) left essentially
        // nothing visible — e.g. a logo whose colour matched its own plate — the
        // logo is unusable. Return nil so the caller falls through to the next
        // source and ultimately the clean styled title, never a blank or boxed logo.
        guard stats.maxX >= stats.minX, stats.maxY >= stats.minY else { return nil }
        // Alpha-weighted opaque fraction of the trimmed bounding box. ~1 when the
        // logo fills its box (a solid plate that was never removed), low for a
        // wordmark surrounded by — and pierced by — transparency.
        let cropArea = Double((stats.maxX - stats.minX + 1) * (stats.maxY - stats.minY + 1))
        let coverage = cropArea > 0 ? min(1.0, weight / cropArea) : 1.0
        let brightInk = weight > 0 ? min(1.0, stats.brightWeight / weight) : 0
        guard let processedFull = Self.makeImage(&data, width: width, height: height, bytesPerRow: bytesPerRow) else {
            return nil
        }
        let cropRect = CGRect(x: stats.minX, y: stats.minY, width: stats.maxX - stats.minX + 1, height: stats.maxY - stats.minY + 1)
        guard let cropped = processedFull.cropping(to: cropRect) else {
            return PreparedLogo(image: UIImage(cgImage: processedFull, scale: scale, orientation: imageOrientation), luminance: luminance, red: meanR, green: meanG, blue: meanB, coverage: coverage, brightInk: brightInk)
        }
        return PreparedLogo(
            image: UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation),
            luminance: luminance,
            red: meanR, green: meanG, blue: meanB,
            coverage: coverage,
            brightInk: brightInk
        )
    }

    /// Builds a CGImage from a premultiplied-RGBA byte buffer. Takes the buffer
    /// `inout` so it can be read in place — `CGContext.makeImage()` copies the
    /// pixels into the returned image, so no defensive copy of `data` is needed.
    private static func makeImage(_ data: inout [UInt8], width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        return data.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Detects a logo shipped on a solid opaque plate (e.g. a black "title card"
    /// box behind the title) and returns its straight (un-premultiplied) RGB, or
    /// `nil` when there is no plate to strip.
    ///
    /// The colour is identified from the border ring; a plate is only reported
    /// when that ring is opaque and near-uniform, the signature of a deliberate
    /// box rather than real artwork — a genuinely transparent logo has a
    /// transparent border, so this returns `nil` for it. Reads the buffer without
    /// mutating it; the actual removal happens in `stripPlateAndMeasure`.
    private static func detectBackgroundPlate(_ data: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> PlateColor? {
        let bpp = 4
        guard width > 2, height > 2 else { return nil }

        // Sample the border ring to estimate the background colour and confirm it
        // is opaque + uniform enough to be a deliberate plate rather than artwork.
        var rSum = 0, gSum = 0, bSum = 0, aSum = 0, count = 0
        func sample(_ x: Int, _ y: Int) {
            let i = y * bytesPerRow + x * bpp
            rSum += Int(data[i]); gSum += Int(data[i + 1]); bSum += Int(data[i + 2]); aSum += Int(data[i + 3])
            count += 1
        }
        for x in stride(from: 0, to: width, by: max(1, width / 64)) {
            sample(x, 0)
            sample(x, height - 1)
        }
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            sample(0, y)
            sample(width - 1, y)
        }
        guard count > 0 else { return nil }

        let avgA = aSum / count
        // A transparent or semi-transparent border means there is no solid plate.
        guard avgA > 250 else { return nil }
        let avgAf = Double(avgA) / 255.0
        // Un-premultiply the averaged border colour to its true RGB.
        let bgR = Double(rSum) / Double(count) / avgAf
        let bgG = Double(gSum) / Double(count) / avgAf
        let bgB = Double(bSum) / Double(count) / avgAf

        // Reject non-uniform borders (real artwork) by checking spread against the
        // mean: if any sampled border pixel is far from the average, bail out.
        var maxDev = 0.0
        func dev(_ x: Int, _ y: Int) {
            let i = y * bytesPerRow + x * bpp
            let a = Double(data[i + 3]) / 255.0
            guard a > 0 else { maxDev = .greatestFiniteMagnitude; return }
            let r = Double(data[i]) / 255.0 / a * 255.0
            let g = Double(data[i + 1]) / 255.0 / a * 255.0
            let b = Double(data[i + 2]) / 255.0 / a * 255.0
            let d = max(abs(r - bgR), max(abs(g - bgG), abs(b - bgB)))
            if d > maxDev { maxDev = d }
        }
        for x in stride(from: 0, to: width, by: max(1, width / 64)) {
            dev(x, 0); dev(x, height - 1)
        }
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            dev(0, y); dev(width - 1, y)
        }
        // Tolerance for "the border is one flat colour". Loose enough to absorb
        // JPEG noise, tight enough to spare gradient/photographic backgrounds.
        guard maxDev <= 26 else { return nil }

        return PlateColor(red: bgR, green: bgG, blue: bgB)
    }

    /// Single fused full-image pass that both strips an opaque background `plate`
    /// (when one was detected) *and* measures the surviving content's bounding
    /// box, alpha-weighted luminance and mean colour. Folding removal and
    /// measurement into one loop halves the per-pixel work versus running them
    /// separately, while producing byte-for-byte identical output.
    ///
    /// Removal is a *global* soft chroma-key, not a border flood-fill: every pixel
    /// near the plate colour is cleared, with a graded edge so anti-aliased
    /// borders feather cleanly. Going global is what clears the colour trapped
    /// *inside* enclosed letter shapes (the counters of B, O, D, P, R…), which a
    /// border-connected flood-fill leaves behind as ugly solid blobs. It is safe
    /// because the plate colour and the logo's bright/coloured letters are far
    /// apart in colour space, so the letters survive intact. Measurement reads the
    /// post-removal alpha so stripped pixels and transparent margins are excluded
    /// from the tone. Operates in place on a premultiplied RGBA buffer.
    private static func stripPlateAndMeasure(
        _ data: inout [UInt8], width: Int, height: Int, bytesPerRow: Int, plate: PlateColor?
    ) -> LogoStats {
        let bpp = 4
        // `innerTol` is the squared colour distance from the plate colour treated
        // as pure background (fully transparent); `outerTol` is where a pixel
        // becomes fully opaque logo. Between them the alpha is graded.
        let innerTol = 45.0 * 45.0
        let outerTol = 120.0 * 120.0

        var stats = LogoStats(minX: width, minY: height, maxX: -1, maxY: -1)
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let i = rowStart + x * bpp

                // Strip the plate first (if any) so the measurement below reads the
                // post-removal alpha.
                if let plate {
                    let oldA = Double(data[i + 3]) / 255.0
                    if oldA > 0 {
                        // Un-premultiply to straight RGB to compare against the plate.
                        let r = Double(data[i]) / 255.0 / oldA * 255.0
                        let g = Double(data[i + 1]) / 255.0 / oldA * 255.0
                        let b = Double(data[i + 2]) / 255.0 / oldA * 255.0
                        let dr = r - plate.red, dg = g - plate.green, db = b - plate.blue
                        let distSq = dr * dr + dg * dg + db * db
                        if distSq <= innerTol {
                            // Pure background: fully transparent.
                            data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 0
                        } else if distSq <= outerTol {
                            // Anti-aliased edge: feather alpha toward 0.
                            let t = (distSq - innerTol) / (outerTol - innerTol)
                            let outA = max(0.0, min(1.0, t)) * oldA
                            // Re-premultiply the original straight RGB by the new alpha.
                            data[i] = UInt8(max(0, min(255, r / 255.0 * outA * 255.0)))
                            data[i + 1] = UInt8(max(0, min(255, g / 255.0 * outA * 255.0)))
                            data[i + 2] = UInt8(max(0, min(255, b / 255.0 * outA * 255.0)))
                            data[i + 3] = UInt8(max(0, min(255, outA * 255.0)))
                        }
                        // else: logo body, leave untouched.
                    }
                }

                // Measure content bounds + tone from the (post-removal) pixel.
                let a = data[i + 3]
                if a > 10 {
                    if x < stats.minX { stats.minX = x }
                    if x > stats.maxX { stats.maxX = x }
                    if y < stats.minY { stats.minY = y }
                    if y > stats.maxY { stats.maxY = y }
                    // Premultiplied buffer: un-premultiply so partly-transparent
                    // edge pixels don't read as artificially dark.
                    let af = Double(a) / 255.0
                    let r = Double(data[i]) / 255.0 / af
                    let g = Double(data[i + 1]) / 255.0 / af
                    let b = Double(data[i + 2]) / 255.0 / af
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    stats.lumaSum += luma * af
                    stats.rSum += r * af
                    stats.gSum += g * af
                    stats.bSum += b * af
                    stats.weight += af
                    // A logo's MEAN tone hides its most legible feature: the white
                    // keyline around a pastel wordmark, or the highlights on a
                    // metallic one, are what actually make it readable, and
                    // averaging them into the fill erases them. Counted separately
                    // in the same pass so a logo that carries its own contrast can
                    // be left alone rather than treated as the mid-tone its mean
                    // claims it is.
                    if luma > PreparedLogo.brightInkLuminance { stats.brightWeight += af }
                }
            }
        }
        return stats
    }
}

/// Straight (un-premultiplied) RGB of a detected solid background plate, 0…255
/// per channel.
private struct PlateColor {
    let red: Double
    let green: Double
    let blue: Double
}

/// Accumulated content bounds + alpha-weighted tone produced by the fused
/// strip/measure pass. `weight` is the summed alpha of measured pixels (the
/// alpha-weighted opaque area).
private struct LogoStats {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var lumaSum = 0.0
    var rSum = 0.0
    var gSum = 0.0
    var bSum = 0.0
    var weight = 0.0
    /// Ink bright enough to carry its own contrast — see
    /// ``PreparedLogo/brightInk``.
    var brightWeight = 0.0
}

/// Samples the effective colour of the hero artwork behind the logo, so the
/// caller can decide whether the logo needs a contrast halo. Fully keyless and
/// on-device: it just downsamples the same backdrop image and averages the
/// left-of-centre band where the logo sits. Returns `nil` when no candidate URL
/// yields a decodable image (the caller then keeps the halo on, to be safe).
public enum HeroBackgroundSampler {
    /// Mean colour + luminance of `region` (normalized, origin top-left) across
    /// the first decodable URL in `urls`. `region` defaults to the left-of-centre
    /// vertical mid-band, which is where the hero's leading-aligned logo renders.
    public static func sample(
        urls: [URL],
        region: CGRect = CGRect(x: 0.0, y: 0.28, width: 0.5, height: 0.40)
    ) async -> HeroBackgroundSample? {
        await sample(
            references: urls.map(ArtworkReference.remote),
            region: region
        )
    }

    /// Samples ordered references through the same decoded-art cache used by the
    /// hero. Network reference keys remain path-free.
    /// - Parameter variant: which decoded size to sample. Defaults to the hero
    ///   backdrop. A **card** should pass the variant it is already displaying, so
    ///   the sample reads an image that is by definition already decoded and
    ///   resident rather than commissioning a larger one.
    public static func sample(
        references: [ArtworkReference],
        region: CGRect = CGRect(x: 0.0, y: 0.28, width: 0.5, height: 0.40),
        variant: ArtworkImageVariant = .heroBackdrop
    ) async -> HeroBackgroundSample? {
        for reference in references {
            if let sample = await Cache.shared.sample(reference, region: region, variant: variant) {
                return sample
            }
        }
        return nil
    }

    /// Memoizes backdrop samples by URL + region. The downsample is cheap per
    /// call but a hero can re-resolve its sample on every appearance / scheme
    /// change, and several detail views can request the same backdrop while
    /// scrolling. Caching the (small, value-type) result — and coalescing
    /// concurrent requests onto one in-flight task that runs off the main actor —
    /// removes that repeated decode/downsample work. A small LRU bound keeps
    /// memory flat across a large library.
    private actor Cache {
        static let shared = Cache()

        private var entries: [String: HeroBackgroundSample] = [:]
        private var order: [String] = []
        private var inFlight: [String: Task<HeroBackgroundSample?, Never>] = [:]
        private let capacity = 32

        func sample(
            _ reference: ArtworkReference,
            region: CGRect,
            variant: ArtworkImageVariant
        ) async -> HeroBackgroundSample? {
            let key = "\(reference.privacySafeIdentity)|\(region.minX),\(region.minY),\(region.width),\(region.height)|\(variant.rawValue)"
            if let hit = entries[key] {
                promote(key)
                return hit
            }
            if let running = inFlight[key] {
                return await running.value
            }
            let task = Task.detached(priority: .utility) {
                await HeroBackgroundSampler.sampleOne(reference, region: region, variant: variant)
            }
            inFlight[key] = task
            let result = await task.value
            inFlight.removeValue(forKey: key)
            if let result {
                store(result, key: key)
            }
            return result
        }

        private func store(_ value: HeroBackgroundSample, key: String) {
            if entries[key] == nil { order.append(key) }
            entries[key] = value
            while order.count > capacity {
                let evicted = order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }

        private func promote(_ key: String) {
            guard let idx = order.firstIndex(of: key) else { return }
            order.remove(at: idx)
            order.append(key)
        }
    }

    private static func sampleOne(
        _ reference: ArtworkReference,
        region: CGRect,
        variant: ArtworkImageVariant
    ) async -> HeroBackgroundSample? {
        guard let image = await ArtworkImageCache.shared.image(for: reference, variant: variant),
              let cg = image.cgImage,
              cg.width > 0,
              cg.height > 0 else {
            return nil
        }

        // Downsample to a tiny thumbnail; we only need an average, so low-quality
        // scaling is plenty and keeps this cheap even for a 4K backdrop.
        let targetW = 100
        let targetH = max(1, Int((Double(cg.height) / Double(cg.width)) * Double(targetW)))
        let bytesPerRow = targetW * 4
        var buf = [UInt8](repeating: 0, count: targetW * targetH * 4)
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: targetW,
                height: targetH,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
            return true
        }
        guard drawn else { return nil }

        // Buffer row 0 is the top of the image, matching the normalized top-left
        // region origin used elsewhere in this file.
        let x0 = max(0, Int(region.minX * Double(targetW)))
        let x1 = min(targetW, max(x0 + 1, Int(region.maxX * Double(targetW))))
        let y0 = max(0, Int(region.minY * Double(targetH)))
        let y1 = min(targetH, max(y0 + 1, Int(region.maxY * Double(targetH))))

        var rSum = 0.0, gSum = 0.0, bSum = 0.0
        var count = 0
        for y in y0..<y1 {
            let rowStart = y * bytesPerRow
            for x in x0..<x1 {
                let i = rowStart + x * 4
                let a = Double(buf[i + 3]) / 255.0
                guard a > 0 else { continue }
                rSum += Double(buf[i]) / 255.0 / a
                gSum += Double(buf[i + 1]) / 255.0 / a
                bSum += Double(buf[i + 2]) / 255.0 / a
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let n = Double(count)
        let r = rSum / n, g = gSum / n, b = bSum / n
        return HeroBackgroundSample(
            red: r, green: g, blue: b,
            luminance: 0.2126 * r + 0.7152 * g + 0.0722 * b
        )
    }
}
#endif
#endif
