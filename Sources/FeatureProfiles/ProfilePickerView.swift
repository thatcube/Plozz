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
/// Focus uses the same theme-aware "inverted card" language as the Settings
/// rows (`SettingsFocusButtonStyle`) — a single custom `ButtonStyle` that owns
/// the entire focus visual. Using a custom style (instead of `.plain` +
/// `focusEffectDisabled`) is what keeps it to ONE focus indicator: the system
/// never layers its own white focus plate over our card.
private struct ProfileTile: View {
    let profile: Profile
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfileTileLabel(profile: profile, isActive: isActive)
        }
        .buttonStyle(ProfilePickerTileStyle())
    }
}

/// The label content for a profile tile. Reads the focus state the
/// `ProfilePickerTileStyle` injects into the environment so the name, active
/// dot, and avatar rim all invert together on the focused card.
private struct ProfileTileLabel: View {
    let profile: Profile
    let isActive: Bool

    @Environment(\.pickerTileIsFocused) private var isFocused
    @Environment(\.pickerTileFocusForeground) private var focusForeground
    @Environment(\.themePalette) private var palette

    private let avatarSize: CGFloat = 200

    var body: some View {
        VStack(spacing: 16) {
            ProfileAvatarView(profile: profile, size: avatarSize)
                .overlay {
                    // On the focused card the photo/disc gets a faint rim in the
                    // inverted foreground so it separates from the fill.
                    Circle().strokeBorder(
                        focusForeground.opacity(isFocused ? 0.18 : 0),
                        lineWidth: 2
                    )
                }

            VStack(spacing: 8) {
                Text(profile.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isFocused ? focusForeground : palette.secondaryText)
                    .lineLimit(1)

                // Subtle "currently active" indicator. Reserves its slot via
                // opacity so active/inactive tiles keep the same rhythm.
                Circle()
                    .fill(isFocused ? focusForeground.opacity(0.55) : palette.accent)
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
        .buttonStyle(ProfilePickerTileStyle())
    }
}

private struct AddProfileTileLabel: View {
    @Environment(\.pickerTileIsFocused) private var isFocused
    @Environment(\.pickerTileFocusForeground) private var focusForeground
    @Environment(\.themePalette) private var palette

    private let avatarSize: CGFloat = 200

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .strokeBorder(
                        (isFocused ? focusForeground : palette.secondaryText)
                            .opacity(isFocused ? 0.9 : 0.5),
                        style: StrokeStyle(lineWidth: 4, dash: [12, 10])
                    )
                Image(systemName: "plus")
                    .font(.system(size: 80, weight: .semibold))
                    .foregroundStyle(isFocused ? focusForeground : palette.secondaryText)
            }
            .frame(width: avatarSize, height: avatarSize)

            VStack(spacing: 8) {
                Text("Add Profile")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isFocused ? focusForeground : palette.secondaryText)

                // Keep the same vertical rhythm as a profile tile's dot slot.
                Circle().fill(.clear).frame(width: 10, height: 10)
            }
        }
    }
}

/// The single, theme-aware focus treatment for every picker tile — the picker's
/// analogue of `FeatureSettings.SettingsFocusButtonStyle`. Owning the focus
/// visual in one custom `ButtonStyle` (rather than `.plain` + a manual
/// `@FocusState` overlay) means tvOS does NOT also paint its default white focus
/// plate, so the tile shows exactly one focus indicator.
///
/// Dark mode focus fills WHITE with BLACK content; light mode fills BLACK with
/// WHITE content. The style injects its focus state + inverted foreground into
/// the environment so the label content can flip its own colors to match.
private struct ProfilePickerTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusBody(configuration: configuration)
    }

    private struct FocusBody: View {
        let configuration: ButtonStyle.Configuration

        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorScheme) private var colorScheme

        private var focusFill: Color { colorScheme == .dark ? .white : .black }
        private var focusForeground: Color { colorScheme == .dark ? .black : .white }

        var body: some View {
            configuration.label
                .environment(\.pickerTileIsFocused, isFocused)
                .environment(\.pickerTileFocusForeground, focusForeground)
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
                .background(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(isFocused ? focusFill : Color.clear)
                        .shadow(color: .black.opacity(isFocused ? 0.28 : 0), radius: 18, y: 8)
                )
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.02 : 1.05) : 1.0)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

// MARK: - Focus-aware environment values (style → label content)

private struct PickerTileIsFocusedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct PickerTileFocusForegroundKey: EnvironmentKey {
    static let defaultValue: Color = .primary
}

private extension EnvironmentValues {
    var pickerTileIsFocused: Bool {
        get { self[PickerTileIsFocusedKey.self] }
        set { self[PickerTileIsFocusedKey.self] = newValue }
    }
    var pickerTileFocusForeground: Color {
        get { self[PickerTileFocusForegroundKey.self] }
        set { self[PickerTileFocusForegroundKey.self] = newValue }
    }
}
#endif
