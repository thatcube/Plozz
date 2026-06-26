#if canImport(SwiftUI)
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
    private let title: String
    private let onSelect: (Profile) -> Void
    private let onAddProfile: (() -> Void)?
    private let onCancel: (() -> Void)?

    @Environment(\.themePalette) private var palette

    public init(
        profiles: [Profile],
        activeProfileID: String?,
        title: String = "Who's watching?",
        onSelect: @escaping (Profile) -> Void,
        onAddProfile: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.title = title
        self.onSelect = onSelect
        self.onAddProfile = onAddProfile
        self.onCancel = onCancel
    }

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 56)]

    /// Which profile tile currently holds focus. Drives the background gradient
    /// so the wash tracks the profile you're hovering. `nil` before focus settles.
    @FocusState private var focusedProfileID: String?
    /// The last profile that held focus, so focusing the non-profile "Add" tile
    /// (or losing focus briefly) keeps the most recent profile's wash instead of
    /// snapping the background away.
    @State private var lastFocusedProfileID: String?
    /// Per-profile resolved colors (instant base + progressive photo extraction).
    @State private var palettes = ProfileBackgroundPalettes()

    /// The profile whose colors the background should currently show: the
    /// focused one, else the last focused, else the active, else the first.
    private var backgroundProfile: Profile? {
        let id = focusedProfileID ?? lastFocusedProfileID ?? activeProfileID
        return profiles.first { $0.id == id } ?? profiles.first
    }

    public var body: some View {
        VStack(spacing: 48) {
            Text(title)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)

            LazyVGrid(columns: columns, spacing: 56) {
                ForEach(profiles) { profile in
                    ProfileTile(
                        profile: profile,
                        isActive: profile.id == activeProfileID
                    ) {
                        onSelect(profile)
                    }
                    .focused($focusedProfileID, equals: profile.id)
                }
                if let onAddProfile {
                    AddProfileTile(action: onAddProfile)
                }
            }
            .padding(.horizontal, 80)
            .focusSection()

            if let onCancel {
                Button("Cancel", action: onCancel)
                    .padding(.top, 8)
                    .focusSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 80)
        .background {
            ProfileBackgroundGradient(profile: backgroundProfile)
        }
        .environment(palettes)
        .onChange(of: focusedProfileID) { _, newValue in
            if let newValue { lastFocusedProfileID = newValue }
        }
        .onAppear { prefetchAvatars() }
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

/// Focus treatment shared by the profile and "Add" tiles: a subtle scale + the
/// circular focus glass live here (the glass itself is drawn by `FocusGlassAvatar`
/// inside the label). Owning focus in a `ButtonStyle` — rather than a `.plain`
/// button with a manual overlay — keeps tvOS from also painting its own focus
/// plate, so the tile shows a single, fully custom indicator.
private struct ProfileTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusBody(configuration: configuration)
    }

    private struct FocusBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var isFocused

        private var scale: CGFloat { PlozzTheme.Metrics.mediumFocusedCardScale }

        var body: some View {
            configuration.label
                .scaleEffect(isFocused ? (configuration.isPressed ? scale * 0.97 : scale) : 1)
                .animation(.easeOut(duration: 0.22), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// A fixed-size avatar slot that shows the shared liquid-glass focus surface as a
/// **circle** around its content (with `focusPadding` of clearance) only when
/// focused — no background at rest. The focused size is always reserved, so
/// focusing never nudges the grid; the glass simply fades in with a soft lift.
private struct FocusGlassAvatar<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: ProfilePickerLayout.slot, height: ProfilePickerLayout.slot)
                .plozzGlassCard(cornerRadius: ProfilePickerLayout.slot / 2, isFocused: true)
                .shadow(color: .black.opacity(0.36), radius: 20, y: 10)
                .opacity(isFocused ? 1 : 0)

            content()
                .frame(width: ProfilePickerLayout.avatarSize, height: ProfilePickerLayout.avatarSize)
        }
        .frame(width: ProfilePickerLayout.slot, height: ProfilePickerLayout.slot)
        .animation(.easeOut(duration: 0.22), value: isFocused)
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
                    .font(.title3.weight(.semibold))
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

/// The trailing "Add Profile" tile shown after the profiles. Only rendered
/// when the caller wants to expose adding (Settings → manage profiles); the
/// launch picker never shows it.
private struct AddProfileTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AddProfileTileLabel()
        }
        .buttonStyle(ProfileTileButtonStyle())
        .focusEffectDisabled()
    }
}

private struct AddProfileTileLabel: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            FocusGlassAvatar {
                ZStack {
                    Circle()
                        .strokeBorder(
                            palette.secondaryText.opacity(isFocused ? 0.9 : 0.5),
                            style: StrokeStyle(lineWidth: 4, dash: [12, 10])
                        )
                    Image(systemName: "plus")
                        .font(.system(size: 80, weight: .semibold))
                        .foregroundStyle(isFocused ? palette.primaryText : palette.secondaryText)
                }
            }

            VStack(spacing: 8) {
                Text("Add Profile")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isFocused ? palette.primaryText : palette.secondaryText)

                // Keep the same vertical rhythm as a profile tile's dot slot.
                Circle().fill(.clear).frame(width: 10, height: 10)
            }
        }
    }
}

/// Shared layout constants so a profile tile and the "Add Profile" tile size
/// identically.
private enum ProfilePickerLayout {
    static let avatarSize: CGFloat = 200
    /// Clearance between the avatar and the circular focus glass — the visible
    /// "padding" the focus halo adds around the avatar when selected.
    static let focusPadding: CGFloat = 24
    /// The reserved avatar-slot size (avatar + focus clearance on each side).
    static let slot: CGFloat = avatarSize + focusPadding * 2
}
#endif
