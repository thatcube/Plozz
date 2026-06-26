#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Resolves the one or two "signature" colors a profile should tint the picker
/// background with, with **progressive enhancement** so the gradient is never
/// blocked on the network:
///
/// 1. Every profile has an **instant** base color from its `colorIndex`
///    (`ProfileTileColor`) — available synchronously on the very first frame, so
///    the background can paint immediately at launch.
/// 2. Photo profiles (`avatarImageURL`) additionally kick off a one-time,
///    off-main-thread extraction of the photo's prominent colors (reusing the
///    shared decoded-image cache + `ArtworkColorExtractor`). When that finishes
///    the resolver publishes the richer palette and the view crossfades to it.
///
/// Results are cached per profile id, so re-focusing a profile is instant and
/// extraction runs at most once per photo. Lightweight by construction: no
/// continuous work, a tiny 256px sample image, and all decode/extract happens on
/// a utility-priority detached task.
@MainActor
@Observable
final class ProfileBackgroundPalettes {
    /// Cached resolved palettes (1–2 colors), keyed by profile id. Observed, so
    /// inserting an extracted palette re-renders any view reading it.
    private var cache: [String: [Color]] = [:]
    /// Profile ids whose photo extraction is in flight, to coalesce work.
    private var inFlight: Set<String> = []

    /// The best palette known *right now* for `profile`. Returns the cached
    /// extracted colors when available; otherwise the instant `colorIndex` base
    /// (and, for photo profiles, schedules a one-time extraction to upgrade it).
    func palette(for profile: Profile) -> [Color] {
        if let cached = cache[profile.id] { return cached }

        let base = [ProfileTileColor.color(forIndex: profile.clampedColorIndex)]
        scheduleExtractionIfNeeded(for: profile)
        return base
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
                ArtworkColorExtractor.palette(from: image, maxColors: 2)
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

/// A subtle, multi-colored gradient bloom across the top of the profile picker,
/// tinted to the focused profile's signature color(s). More present than the
/// app-wide `AppBackground` top glow, but still a soft ambient wash — it sits
/// *behind* the picker content and never competes with it.
///
/// As focus moves between profiles the bloom **crossfades** to the new colors
/// and **shifts** its anchor slightly (each profile gets a deterministic offset
/// from its id), so switching profiles reads as a gentle, living transition.
/// The whole layer fades in on first appearance so launch feels elegant rather
/// than abrupt. Honors Reduce Motion by dropping the positional shift.
struct ProfileBackgroundGradient: View {
    /// The profile whose colors drive the bloom. `nil` paints nothing extra.
    let profile: Profile?

    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ProfileBackgroundPalettes.self) private var palettes

    @State private var appeared = false

    var body: some View {
        let colors = resolvedColors
        ZStack {
            // Primary bloom — the dominant signature color, anchored near the top.
            RadialGradient(
                gradient: Gradient(colors: [colors.primary.opacity(primaryOpacity), .clear]),
                center: primaryAnchor,
                startRadius: 0,
                endRadius: 980
            )
            // Secondary bloom — a smaller accent from the opposite side for the
            // "multi-colored" feel without muddying the field.
            RadialGradient(
                gradient: Gradient(colors: [colors.secondary.opacity(secondaryOpacity), .clear]),
                center: secondaryAnchor,
                startRadius: 0,
                endRadius: 760
            )
        }
        .ignoresSafeArea()
        .opacity(appeared ? 1 : 0)
        // Crossfade colors/anchors when the focused profile changes; the slower
        // curve keeps the shift calm and ambient.
        .animation(.easeInOut(duration: 0.8), value: profile?.id)
        .animation(.easeInOut(duration: 0.8), value: colors)
        .onAppear {
            // Gentle fade-in on first paint so the background arrives elegantly
            // instead of popping in at launch.
            withAnimation(.easeOut(duration: 0.7)) { appeared = true }
        }
    }

    // MARK: Colors

    private struct ResolvedColors: Equatable {
        var primary: Color
        var secondary: Color
    }

    private var resolvedColors: ResolvedColors {
        guard let profile else {
            return ResolvedColors(primary: .clear, secondary: .clear)
        }
        let resolved = palettes.palette(for: profile)
        let primary = resolved.first ?? ProfileTileColor.color(forIndex: profile.clampedColorIndex)
        // If only one color is known, synthesise a gently shifted partner so the
        // two blooms still read as "multi-colored" rather than a flat single hue.
        let secondary = resolved.count > 1 ? resolved[1] : ProfileBackgroundGradient.shifted(primary)
        return ResolvedColors(primary: primary, secondary: secondary)
    }

    // MARK: Per-theme strength

    private var primaryOpacity: Double { colorScheme == .dark ? 0.55 : 0.30 }
    private var secondaryOpacity: Double { colorScheme == .dark ? 0.38 : 0.22 }

    // MARK: Anchors (deterministic per-profile shift)

    /// A stable 0–1 value derived from the profile id, used to nudge the bloom
    /// so consecutive profiles visibly shift. Reduce Motion pins it to centre.
    private var shift: CGFloat {
        guard !reduceMotion, let profile else { return 0.5 }
        let hash = abs(profile.id.hashValue % 1000)
        return 0.32 + CGFloat(hash) / 1000.0 * 0.36 // ~0.32...0.68
    }

    private var primaryAnchor: UnitPoint {
        UnitPoint(x: shift, y: 0.02)
    }

    private var secondaryAnchor: UnitPoint {
        // Opposite side of the primary, kept high so the wash stays "across the top".
        UnitPoint(x: 1.0 - shift, y: 0.14)
    }

    // MARK: Single-color partner synthesis

    /// Derives a subtly different companion color from a single base color by
    /// rotating its hue a little and lifting brightness — enough variety for a
    /// two-tone bloom without introducing a clashing color.
    static func shifted(_ color: Color) -> Color {
        #if canImport(UIKit)
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        let newHue = (h + 0.06).truncatingRemainder(dividingBy: 1.0)
        return Color(hue: Double(newHue),
                     saturation: Double(min(s * 1.05, 1.0)),
                     brightness: Double(min(b * 1.12, 1.0)))
        #else
        return color
        #endif
    }
}
#endif
