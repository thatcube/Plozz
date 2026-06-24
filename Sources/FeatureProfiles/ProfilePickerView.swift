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
/// profile name, with a tvOS focus scale + an "active" badge.
private struct ProfileTile: View {
    let profile: Profile
    let isActive: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.themePalette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                ProfileAvatarView(profile: profile, size: 220)
                .overlay(alignment: .topTrailing) {
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.green)
                            .background(Circle().fill(.white))
                            .offset(x: 6, y: -6)
                    }
                }
                .overlay(
                    Circle()
                        .strokeBorder(palette.accent, lineWidth: isFocused ? 8 : 0)
                )
                .scaleEffect(isFocused ? 1.12 : 1.0)
                .shadow(radius: isFocused ? 24 : 0)

                Text(profile.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isFocused ? palette.primaryText : palette.secondaryText)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// The trailing "Add Profile" tile shown after the profiles. Only rendered
/// when the caller wants to expose adding (Settings → manage profiles); the
/// launch picker never shows it.
private struct AddProfileTile: View {
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.themePalette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .strokeBorder(palette.secondaryText.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 4, dash: [12, 10]))
                    Image(systemName: "plus")
                        .font(.system(size: 88, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(width: 220, height: 220)
                .overlay(
                    Circle()
                        .strokeBorder(palette.accent, lineWidth: isFocused ? 8 : 0)
                )
                .scaleEffect(isFocused ? 1.12 : 1.0)

                Text("Add Profile")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isFocused ? palette.primaryText : palette.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}
#endif
