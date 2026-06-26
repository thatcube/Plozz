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

/// A single selectable profile tile: avatar on a colored disc plus the name.
///
/// Focus reuses the **same liquid-glass card surface as the Home page tiles**
/// (`plozzCardButton` → `PlozzCardButtonStyle`): a subtle theme-aware glass
/// wash at rest that lifts into a brighter tinted glass on focus, with a gentle
/// scale + soft shadow. The shared style also disables tvOS's default white
/// focus plate, so there's exactly one focus indicator. The active profile
/// carries a small, quiet accent dot under its name.
private struct ProfileTile: View {
    let profile: Profile
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfileTileLabel(profile: profile, isActive: isActive)
        }
        .plozzCardButton(cornerRadius: ProfilePickerLayout.tileCornerRadius)
    }
}

/// The label content for a profile tile. Reads `\.isFocused` (the picker tile's
/// focusable button propagates it) so the name and active dot gently emphasise
/// on the focused glass card.
private struct ProfileTileLabel: View {
    let profile: Profile
    let isActive: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(spacing: 16) {
            ProfileAvatarView(profile: profile, size: ProfilePickerLayout.avatarSize)

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
        .padding(ProfilePickerLayout.tilePadding)
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
        .plozzCardButton(cornerRadius: ProfilePickerLayout.tileCornerRadius)
    }
}

private struct AddProfileTileLabel: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(spacing: 16) {
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
            .frame(width: ProfilePickerLayout.avatarSize, height: ProfilePickerLayout.avatarSize)

            VStack(spacing: 8) {
                Text("Add Profile")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isFocused ? palette.primaryText : palette.secondaryText)

                // Keep the same vertical rhythm as a profile tile's dot slot.
                Circle().fill(.clear).frame(width: 10, height: 10)
            }
        }
        .padding(ProfilePickerLayout.tilePadding)
    }
}

/// Shared layout constants so a profile tile and the "Add Profile" tile size
/// identically.
private enum ProfilePickerLayout {
    static let avatarSize: CGFloat = 200
    static let tilePadding: CGFloat = 24
    static let tileCornerRadius: CGFloat = PlozzTheme.Metrics.mediumCardCornerRadius
}
#endif
