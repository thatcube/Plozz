#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Resolves the "signature" colors a profile should tint the picker background
/// with, with **progressive enhancement** so the gradient is never blocked on
/// the network:
///
/// 1. Every profile has an **instant** base color from its `colorIndex`
///    (`ProfileTileColor`) — available synchronously on the very first frame, so
///    the background can paint immediately at launch. A single hue is expanded
///    into a small harmonious set so even solid-color profiles drive a rich,
///    multi-tone morphing field rather than one flat color.
/// 2. Photo profiles (`avatarImageURL`) additionally kick off a one-time,
///    off-main-thread extraction of the photo's prominent colors (reusing the
///    shared decoded-image cache + `ArtworkColorExtractor`). When that finishes
///    the resolver publishes the richer palette and the view crossfades to it.
///
/// Results are cached per profile id, so re-focusing a profile is instant and
/// extraction runs at most once per photo. Lightweight by construction: a tiny
/// 256px sample image, and all decode/extract happens on a utility-priority
/// detached task.
@MainActor
@Observable
final class ProfileBackgroundPalettes {
    /// Cached *extracted* palettes (multiple colors), keyed by profile id.
    /// Observed, so inserting an extracted palette re-renders any view reading it.
    private var cache: [String: [Color]] = [:]
    /// Profile ids whose photo extraction is in flight, to coalesce work.
    private var inFlight: Set<String> = []

    /// The best palette known *right now* for `profile`, always ≥ 4 colors so the
    /// mesh has plenty to morph between — *unless* the profile uses a photo whose
    /// colors haven't been extracted yet, in which case it returns an empty
    /// palette (a calm neutral field) and schedules extraction. That avoids
    /// flashing the profile's unrelated assigned `colorIndex` tint (e.g. purple)
    /// for a beat before the real photo colors crossfade in. Symbol-only profiles
    /// have no photo, so their `colorIndex` *is* their identity and is used
    /// instantly.
    func palette(for profile: Profile) -> [Color] {
        if let cached = cache[profile.id] { return cached }

        if hasPhoto(profile) {
            // Photo profile, colors not extracted yet: stay neutral and let the
            // real photo colors fade in, rather than showing the assigned tint.
            scheduleExtractionIfNeeded(for: profile)
            return []
        }

        // Symbol-only profile: the tile color is the identity — show it at once.
        return Self.harmonized(ProfileTileColor.color(forIndex: profile.clampedColorIndex))
    }

    /// Whether a profile has a usable avatar photo URL.
    private func hasPhoto(_ profile: Profile) -> Bool {
        guard let raw = profile.avatarImageURL?.trimmingCharacters(in: .whitespaces) else { return false }
        return !raw.isEmpty
    }

    /// Expands a single base color into a small set of analogous tones (hue
    /// rotated a little either way, plus a lighter and a deeper variant) so a
    /// solid-color profile still produces a lively, multi-tone morphing field
    /// instead of a flat wash.
    static func harmonized(_ base: Color) -> [Color] {
        #if canImport(UIKit)
        let ui = UIColor(base)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return [base, base, base, base]
        }
        func make(_ dh: CGFloat, _ ds: CGFloat, _ db: CGFloat) -> Color {
            Color(hue: Double((h + dh).truncatingRemainder(dividingBy: 1.0) + (h + dh < 0 ? 1 : 0)),
                  saturation: Double(min(max(s + ds, 0), 1)),
                  brightness: Double(min(max(b + db, 0), 1)))
        }
        return [
            make(0.0,  0.05,  0.06),   // the base, a touch richer
            make(0.05, 0.00,  0.12),   // warmer/lighter neighbour
            make(-0.05, 0.04, -0.06),  // cooler/deeper neighbour
            make(0.10, -0.05, 0.16)    // bright far accent
        ]
        #else
        return [base, base, base, base]
        #endif
    }

    /// Kicks off photo-color extraction for a profile once, if it has a usable
    /// avatar URL and hasn't already been resolved or started.
    private func scheduleExtractionIfNeeded(for profile: Profile) {
        #if canImport(UIKit)
        guard cache[profile.id] == nil, !inFlight.contains(profile.id) else { return }
        guard
            let raw = profile.avatarImageURL?.trimmingCharacters(in: .whitespaces),
            !raw.isEmpty,
            let url = URL(string: raw)
        else { return }

        inFlight.insert(profile.id)
        let id = profile.id
        Task { [weak self] in
            // Reuse the shared cache (the tile likely already decoded this photo),
            // then extract off the main thread so the UI never stalls.
            guard let image = await ArtworkImageCache.shared.image(for: url, variant: .musicThumbnail) else {
                self?.inFlight.remove(id)
                return
            }
            let colors = await Task.detached(priority: .utility) {
                ArtworkColorExtractor.palette(from: image, maxColors: 4)
            }.value

            guard let self else { return }
            self.inFlight.remove(id)
            if !colors.isEmpty {
                self.cache[id] = colors
            }
        }
        #endif
    }
}

/// The profile picker's living background: the **same Apple Music–style morphing
/// mesh** used by the now-playing screen (`LiquidArtworkBackground`), tinted to
/// the focused profile's signature color(s). It fills the screen — colors drift
/// and blend on slow, out-of-phase waves — so the picker feels alive the moment
/// it appears.
///
/// As focus moves between profiles the palette changes and the mesh **crossfades**
/// to the new colors (handled by `LiquidArtworkBackground`'s own colour
/// animation), so switching profiles reads as a gentle, fluid transition. The
/// whole layer fades in on first appearance so launch feels elegant rather than
/// abrupt. Reduce Motion renders the field statically.
struct ProfileBackgroundGradient: View {
    /// The profile whose colors drive the field. `nil` shows the neutral field.
    let profile: Profile?
    /// Where the colored glow is centered, in unit coordinates of this view —
    /// nominally the focused profile tile's position, so the color pools around
    /// the icon you're looking at rather than washing the whole screen.
    var focal: UnitPoint = .center

    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ProfileBackgroundPalettes.self) private var palettes

    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            LiquidArtworkBackground(
                palette: resolvedColors,
                animate: !reduceMotion,
                style: style,
                paletteCrossfade: 1.8,
                showsBackdrop: false
            )
            // Pool the color into a soft glow around the focused icon and let it
            // fade out to the app's normal background, so the field reads as a
            // localized tint rather than a full-screen wash.
            .mask { glowMask(in: proxy.size) }
            .animation(.easeOut(duration: 0.6), value: focal)
        }
        .ignoresSafeArea()
        .opacity(appeared ? 1 : 0)
        .onAppear {
            // Gentle fade-in on first paint so the background arrives elegantly
            // instead of popping in at launch.
            withAnimation(.easeOut(duration: 0.9)) { appeared = true }
        }
    }

    /// A gentle center-weighting that never cuts off: the color is a little
    /// stronger around the focused icon and eases down toward the edges, but
    /// stays faintly present all the way out (no hard ring). Kept low-alpha for
    /// an OLED-like subtlety rather than a bright spotlight.
    private func glowMask(in size: CGSize) -> some View {
        let radius = max(size.width, size.height) * 0.95
        return RadialGradient(
            stops: [
                .init(color: .white.opacity(0.50), location: 0.0),
                .init(color: .white.opacity(0.30), location: 0.5),
                .init(color: .white.opacity(0.14), location: 1.0)
            ],
            center: focal,
            startRadius: 0,
            endRadius: radius
        )
        .ignoresSafeArea()
    }

    /// Colors for the mesh: the focused profile's extracted/harmonised palette,
    /// or an empty array (neutral field) before focus settles.
    private var resolvedColors: [Color] {
        guard let profile else { return [] }
        return palettes.palette(for: profile)
    }

    /// Maps the active theme onto a `LiquidArtworkBackground` treatment: OLED
    /// stays near-black with the colors as faint accents, Light gets the frosted
    /// veil, everything else the standard dark scrim.
    private var style: LiquidArtworkBackground.Style {
        if palette == .oled { return .oled }
        if colorScheme == .light { return .light }
        return .dark
    }
}
#endif
