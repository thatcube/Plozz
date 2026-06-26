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
    }
}

/// A single selectable profile tile: avatar symbol on a colored disc plus the
/// profile name. On focus it lifts onto a soft, theme-aware Liquid Glass
/// platter (rounded, translucent) with a gentle scale + shadow — no stark white
/// system plate. The active profile carries a small, quiet accent dot under its
/// name rather than a corner badge, so the indicator never collides with focus.
private struct ProfileTile: View {
    let profile: Profile
    let isActive: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.themePalette) private var palette

    private let avatarSize: CGFloat = 200

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                ProfileAvatarView(profile: profile, size: avatarSize)
                    .overlay {
                        // Thin, theme-aware rim for crisp definition on focus.
                        Circle().strokeBorder(
                            palette.primaryText.opacity(isFocused ? 0.9 : 0),
                            lineWidth: 3
                        )
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
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .plozzFocusPlatter(cornerRadius: 36, isFocused: isFocused)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 24, y: 12)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}

/// The trailing "Add Profile" tile shown after the profiles. Only rendered
/// when the caller wants to expose adding (Settings → manage profiles); the
/// launch picker never shows it.
private struct AddProfileTile: View {
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.themePalette) private var palette

    private let avatarSize: CGFloat = 200

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .strokeBorder(palette.secondaryText.opacity(isFocused ? 0.9 : 0.5),
                                      style: StrokeStyle(lineWidth: 4, dash: [12, 10]))
                    Image(systemName: "plus")
                        .font(.system(size: 80, weight: .semibold))
                        .foregroundStyle(isFocused ? palette.primaryText : palette.secondaryText)
                }
                .frame(width: avatarSize, height: avatarSize)

                VStack(spacing: 8) {
                    Text("Add Profile")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isFocused ? palette.primaryText : palette.secondaryText)

                    // Keep the same vertical rhythm as a profile tile's dot slot.
                    Circle().fill(.clear).frame(width: 10, height: 10)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .plozzFocusPlatter(cornerRadius: 36, isFocused: isFocused)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 24, y: 12)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}
#endif
