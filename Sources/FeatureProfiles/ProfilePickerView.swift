#if os(tvOS)
import SwiftUI
import CoreModels
import CoreUI

/// tvOS profile picker — the "Who's watching?" screen.
///
/// Selection-only. Tapping a tile activates that profile; there is no Edit
/// mode and no per-tile account toggles. Profile editing lives in Settings →
/// Profile after selection. An "Add Profile" tile is shown only when the
/// caller passes a non-nil `onAddProfile` (i.e. from Settings → "Manage
/// Profiles"); the launch picker hides it.
public struct ProfilePickerView: View {
    private let profiles: [Profile]
    private let activeProfileID: String?
    private let title: LocalizedStringResource
    private let onSelect: (Profile) -> Void
    private let onAddProfile: (() -> Void)?
    /// Opens the focused profile's settings. When non-nil an Edit affordance
    /// appears under whichever tile has focus.
    private let onEditProfile: ((Profile) -> Void)?
    /// Creates a restricted profile directly. A separate entry point rather than
    /// a toggle buried in the editor, the way YouTube splits "Add account" from
    /// "Add a kid account": the decision is clearest at the moment of creation,
    /// and it means the restriction is on from the profile's first second rather
    /// than after a trip through Settings.
    private let onAddKidsProfile: (() -> Void)?
    private let onCancel: (() -> Void)?

    @Environment(\.themePalette) private var palette

    public init(
        profiles: [Profile],
        activeProfileID: String?,
        title: LocalizedStringResource = "Who's watching?",
        onSelect: @escaping (Profile) -> Void,
        onAddProfile: (() -> Void)? = nil,
        onEditProfile: ((Profile) -> Void)? = nil,
        onAddKidsProfile: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.title = title
        self.onSelect = onSelect
        self.onAddProfile = onAddProfile
        self.onEditProfile = onEditProfile
        self.onAddKidsProfile = onAddKidsProfile
        self.onCancel = onCancel
    }


    /// What currently holds focus. Richer than a profile id because each column
    /// now has two focusable controls — the tile and its own Edit button — and
    /// the column needs to stay "open" while either of them is focused.
    @FocusState private var focus: PickerFocus?

    /// The profile the focus is currently within, whichever of its two controls
    /// holds it. Drives the background wash. `nil` while focus is on an Add tile
    /// or before focus settles.
    private var focusedProfileID: String? {
        switch focus {
        case let .profile(id), let .edit(id): return id
        default: return nil
        }
    }
    /// The profile the background has actually *committed* to. Updated only after
    /// focus rests on a tile for `backgroundSettleDelay`, so sweeping across tiles
    /// (1 → 2 → 3) skips the in-between profiles entirely — the wash only fades to
    /// where you land and pause, never to the ones you pass through.
    @State private var settledProfileID: String?
    /// Per-profile resolved colors (instant base + progressive photo extraction).
    @State private var palettes = ProfileBackgroundPalettes()

    /// How long focus must rest on a tile before the background fades to it.
    private let backgroundSettleDelay: Duration = .milliseconds(300)
    /// Guards the one-time programmatic initial focus so later re-renders don't
    /// keep yanking focus back to the default tile.
    @State private var didSetInitialFocus = false

    /// The profile whose colors the background should currently show. Before
    /// focus settles (i.e. at startup) it is pinned to the **default-focused**
    /// profile — the last-active one if there is one, else the first tile — which
    /// is exactly the tile tvOS opens focus on. Because the opening focus and the
    /// opening wash agree, the background never flashes a different profile's
    /// color before settling. Once focus rests on a tile, that tile drives it.
    private var backgroundProfile: Profile? {
        let id = settledProfileID ?? defaultFocusID
        return profiles.first { $0.id == id } ?? profiles.first
    }

    /// The tile that should hold focus when the picker first appears: the
    /// last-active profile (so resuming is a single click), falling back to the
    /// first profile on a first-ever launch with no active profile.
    private var defaultFocusID: String? {
        activeProfileID ?? profiles.first?.id
    }

    /// Resolve the *settled* (else default) tile's center into unit coordinates
    /// of the background, so the colored glow pools around the icon the wash has
    /// committed to. Deliberately driven by `settledProfileID`, **not** the live
    /// `focusedProfileID`: if the glow chased raw focus it would animate its
    /// full-screen mask center on every focus move, stacking overlapping 0.6s
    /// transitions and re-rendering the whole background as you sweep across
    /// tiles — the source of the rapid-focus lag. Tracking the settled profile
    /// instead means a fast sweep does zero background work; the glow only eases
    /// to where you land and pause, which is the intended "settle-then-fade"
    /// behaviour. Falls back to centre before any tile is measured.
    private func focalPoint(centers: [String: Anchor<CGPoint>], proxy: GeometryProxy) -> UnitPoint {
        let id = settledProfileID ?? defaultFocusID
        guard let id, let anchor = centers[id] else { return .center }
        let point = proxy[anchor]
        let size = proxy.size
        guard size.width > 0, size.height > 0 else { return .center }
        return UnitPoint(x: point.x / size.width, y: point.y / size.height)
    }


    /// Each column's own Edit button, directly beneath its avatar.
    ///
    /// Rendered for every profile rather than as one shared slot, so it reads as
    /// belonging to the profile it sits under. It's always present in the layout
    /// — a button that only *existed* while focused could never receive the Down
    /// press meant to reach it — but it only becomes visible when focus is
    /// somewhere in that column, so the row stays quiet while you scan across it.
    @ViewBuilder
    private func editButton(for profile: Profile, onEdit: @escaping (Profile) -> Void) -> some View {
        let isRevealed = focusedProfileID == profile.id
        Button {
            onEdit(profile)
        } label: {
            Text("Edit")
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .focused($focus, equals: .edit(profile.id))
        .opacity(isRevealed ? 1 : 0)
        // Unreachable when hidden, so the focus engine can't land on an
        // invisible control coming from an odd angle.
        .disabled(!isRevealed)
        .animation(.easeOut(duration: 0.15), value: isRevealed)
    }

    public var body: some View {
        VStack(spacing: 48) {
            Text(title)
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(palette.primaryText)

            // One horizontal run rather than a wrapping grid. Profiles are a
            // short list you scan left-to-right, and a single row keeps the
            // Edit affordance directly under whatever has focus — with a grid
            // it would have to sit under a *row*, which reads as belonging to
            // all of them.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: ProfilePickerLayout.tileSpacing) {
                    ForEach(profiles) { profile in
                        VStack(spacing: 20) {
                            ProfileTile(
                                profile: profile,
                                isActive: profile.id == activeProfileID
                            ) {
                                onSelect(profile)
                            }
                            .focused($focus, equals: .profile(profile.id))
                            .anchorPreference(key: TileCentersKey.self, value: .center) {
                                [profile.id: $0]
                            }

                            if let onEditProfile {
                                editButton(for: profile, onEdit: onEditProfile)
                            }
                        }
                        // Keep each profile's tile and its Edit button in one
                        // focus region, so Down reaches that column's button
                        // rather than the nearest one in another column.
                        .focusSection()
                    }
                    if let onAddProfile {
                        AddProfileTile(
                            title: "Add Profile",
                            systemImage: "plus",
                            isProminent: true,
                            action: onAddProfile
                        )
                        .focused($focus, equals: .add)
                    }
                    if let onAddKidsProfile {
                        AddProfileTile(
                            title: KidsProfileCopy.addTile,
                            systemImage: "figure.and.child.holdinghands",
                            isProminent: false,
                            action: onAddKidsProfile
                        )
                        .focused($focus, equals: .addKids)
                    }
                }
                .padding(.horizontal, ProfilePickerLayout.rowPadding)
                // Room for the focus halo + lift, which would otherwise be
                // clipped by the scroll view's bounds.
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .focusSection()

            if let onCancel {
                Button("Cancel", action: onCancel)
                    .padding(.top, 8)
                    .focusSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 80)
        .backgroundPreferenceValue(TileCentersKey.self) { centers in
            GeometryReader { proxy in
                ProfileBackgroundGradient(
                    profile: backgroundProfile,
                    focal: focalPoint(centers: centers, proxy: proxy)
                )
            }
            .ignoresSafeArea()
        }
        .environment(palettes)
        .task(id: focusedProfileID) {
            // Debounce: wait for focus to rest before committing the background.
            // If focus moves again the task is cancelled and restarted, so the
            // profiles you sweep past never get a chance to fade in — only the
            // one you actually pause on does. Focusing the "Add" tile (nil) keeps
            // the last settled wash rather than snapping away.
            guard let id = focusedProfileID else { return }
            do { try await Task.sleep(for: backgroundSettleDelay) } catch { return }
            settledProfileID = id
        }
        .onAppear {
            prefetchAvatars()
            setInitialFocusIfNeeded()
        }
    }

    /// Move focus to the default tile (last-used profile, else first) once when
    /// the picker appears. tvOS's declarative `.defaultFocus` is unreliable with
    /// `LazyVGrid`, so we set the `@FocusState` explicitly after a short runloop
    /// hop — letting the focus engine finish its first pass — which dependably
    /// pre-selects the right tile.
    private func setInitialFocusIfNeeded() {
        guard !didSetInitialFocus else { return }
        didSetInitialFocus = true
        guard let target = defaultFocusID else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            focus = .profile(target)
        }
    }

    /// Warm the decoded-image cache for every profile photo as soon as the picker
    /// appears, so the tiles' `FallbackAsyncImage` seeds synchronously and the
    /// photos pop in with no neutral-placeholder gap. Cheap and fire-and-forget.
    private func prefetchAvatars() {
        #if canImport(UIKit)
        for profile in profiles {
            guard
                let raw = profile.avatarImageURL?.trimmingCharacters(in: .whitespaces),
                !raw.isEmpty,
                let url = URL(string: raw)
            else { continue }
            ArtworkImageCache.shared.prefetch(url, variant: .posterCard)
        }
        #endif
    }
}

/// What holds focus in the picker.
///
/// A plain profile id isn't enough now that each column owns two focusable
/// controls: the column has to stay revealed while focus sits on either the tile
/// or its Edit button, and the Add tiles need identities that can't collide with
/// a profile id.
private enum PickerFocus: Hashable {
    case profile(String)
    case edit(String)
    case add
    case addKids
}

/// Collects each profile tile's center point (as an `Anchor`) keyed by profile
/// id, so the background can look up the focused tile's position and pool its
/// color glow there.
private struct TileCentersKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGPoint>] = [:]
    static func reduce(value: inout [String: Anchor<CGPoint>], nextValue: () -> [String: Anchor<CGPoint>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A single selectable profile tile: a circular avatar with the name beneath it.
///
/// At rest the tile has **no background** — just the avatar and name. On focus a
/// circular liquid-glass surface (the same focused "card" treatment used across
/// the app, reused via `plozzGlassCard`) blooms behind the avatar with 24pt of
/// clearance so it reads as a round halo, and the whole tile lifts with a gentle
/// scale + shadow. The name sits *below* the glass, never inside it. A custom
/// `ButtonStyle` owns focus (with the system focus effect disabled) so there's
/// exactly one focus indicator. The active profile carries a small accent dot.
private struct ProfileTile: View {
    let profile: Profile
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfileTileLabel(profile: profile, isActive: isActive)
        }
        .buttonStyle(ProfileTileButtonStyle())
        .focusEffectDisabled()
    }
}

/// Focus treatment shared by the profile and "Add" tiles. Owning focus in a
/// `ButtonStyle` — rather than a `.plain` button with a manual overlay — keeps
/// tvOS from also painting its own focus plate, so the tile shows a single,
/// fully custom indicator. The focus scale is applied to the *photo only*
/// (inside `FocusGlassAvatar`); here we just add momentary press feedback to the
/// avatar so the name and active dot keep a constant size.
private struct ProfileTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.profileTilePressed, configuration.isPressed)
    }
}

/// A fixed-size avatar slot that shows the shared liquid-glass focus surface as a
/// **circle** around its content (with `focusPadding` of clearance) only when
/// focused — no background at rest. On focus the *photo* gently scales up toward
/// the halo while the glass stays put; the surrounding text is unaffected. The
/// focused size is always reserved, so focusing never nudges the grid; the glass
/// simply fades in with a soft lift.
private struct FocusGlassAvatar<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.isFocused) private var isFocused
    @Environment(\.profileTilePressed) private var isPressed

    var body: some View {
        CircularFocusHalo(
            isFocused: isFocused,
            isPressed: isPressed,
            diameter: ProfilePickerLayout.avatarSize,
            focusPadding: ProfilePickerLayout.focusPadding,
            avatar: content
        )
    }
}

private struct ProfileTilePressedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var profileTilePressed: Bool {
        get { self[ProfileTilePressedKey.self] }
        set { self[ProfileTilePressedKey.self] = newValue }
    }
}

/// The label content for a profile tile. Reads `\.isFocused` (the focusable
/// button propagates it) so the name gently emphasises on focus.
private struct ProfileTileLabel: View {
    let profile: Profile
    let isActive: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            FocusGlassAvatar {
                ProfileAvatarView(profile: profile, size: ProfilePickerLayout.avatarSize)
            }

            VStack(spacing: 8) {
                Text(profile.name)
                    .font(ProfilePickerLayout.nameFont)
                    .foregroundStyle(isFocused ? palette.primaryText : palette.secondaryText)
                    .lineLimit(1)

                // Subtle "currently active" indicator. Reserves its slot via
                // opacity so active/inactive tiles keep the same rhythm.
                Circle()
                    .fill(palette.accent)
                    .frame(width: 10, height: 10)
                    .opacity(isActive ? 1 : 0)
            }
        }
    }
}

/// A trailing "create something" tile. Two of these can appear — an ordinary
/// profile and a Kids Profile — mirroring how YouTube offers "Add account" and
/// "Add a kid account" side by side rather than hiding the distinction behind a
/// toggle. Only rendered when the caller passes the matching closure; the launch
/// picker shows neither.
private struct AddProfileTile: View {
    let title: LocalizedStringResource
    let systemImage: String
    /// The plain "Add Profile" tile is the primary action and gets the solid
    /// treatment; the kid variant is deliberately quieter so it doesn't compete.
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AddProfileTileLabel(title: title, systemImage: systemImage, isProminent: isProminent)
        }
        .buttonStyle(ProfileTileButtonStyle())
        .focusEffectDisabled()
    }
}

private struct AddProfileTileLabel: View {
    let title: LocalizedStringResource
    let systemImage: String
    let isProminent: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            FocusGlassAvatar {
                ZStack {
                    if isProminent {
                        Circle().fill(isFocused ? Color.white : palette.primaryText.opacity(0.9))
                    } else {
                        Circle()
                            .strokeBorder(
                                palette.secondaryText.opacity(isFocused ? 0.9 : 0.5),
                                style: StrokeStyle(lineWidth: 4, dash: [12, 10])
                            )
                    }
                    Image(systemName: systemImage)
                        .font(.system(size: isProminent ? 102 : 88, weight: .semibold))
                        .foregroundStyle(
                            isProminent
                                ? (isFocused ? Color.black : palette.settingsBackground)
                                : (isFocused ? palette.primaryText : palette.secondaryText)
                        )
                }
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(ProfilePickerLayout.nameFont)
                    .foregroundStyle(isFocused ? palette.primaryText : palette.secondaryText)
                    .lineLimit(1)

                // Keep the same vertical rhythm as a profile tile's dot slot.
                Circle().fill(.clear).frame(width: 10, height: 10)
            }
        }
    }
}

/// Shared layout constants so a profile tile and the "Add Profile" tile size
/// identically.
private enum ProfilePickerLayout {
    /// Deliberately large: the avatar IS the target on this screen, and a 10-foot
    /// UI can afford it.
    ///
    /// Sized so five still fit without scrolling, which is the common household
    /// count. tvOS reserves ~60pt of title-safe inset per side, leaving ~1800 of
    /// a 1920 screen, and everything below has to live inside that:
    ///
    ///     5×(256 + 2×24) + 4×36 + 2×40 = 1520 + 144 + 80 = 1744
    ///
    /// The halo's clearance is NOT the place to find room — shrinking it made
    /// the focus ring read as a thin rim instead of a halo. The gaps and the row
    /// inset give way first; past that, growing the avatar trades the fifth tile
    /// for size. Change these together rather than one at a time.
    static let avatarSize: CGFloat = 256
    /// Clearance between the avatar and the circular focus glass — the visible
    /// "padding" the focus halo adds around the avatar when selected.
    ///
    /// This is what makes focus read as a *halo* rather than an outline, so it
    /// scales with the avatar instead of absorbing the layout budget.
    static let focusPadding: CGFloat = 24
    /// The reserved avatar-slot size (avatar + focus clearance on each side).
    static let slot: CGFloat = avatarSize + focusPadding * 2
    /// Sized against the avatar so five still fit without scrolling; the slack
    /// the smaller avatar frees goes back into breathing room rather than being
    /// hoarded.
    static let tileSpacing: CGFloat = 36
    /// Row inset, inside the tvOS title-safe area.
    static let rowPadding: CGFloat = 40
    /// Deliberately generous for a 10-foot screen: the name is read at a glance
    /// from a sofa, and it's the only text on the tile.
    static let nameFont: Font = .system(size: 34, weight: .semibold)
}
#endif
