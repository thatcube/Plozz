#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// tvOS profile picker — the "Who's watching?" screen.
///
/// Shown at launch (when the household has more than one profile and no
/// remembered selection) and from Settings via "Switch Profile". Selecting a
/// tile activates that profile; the optional **Edit** mode routes tile taps to
/// the editor instead, and exposes an "Add Profile" tile.
public struct ProfilePickerView: View {
    private let profiles: [Profile]
    private let activeProfileID: String?
    private let title: String
    private let onSelect: (Profile) -> Void
    private let onAddProfile: () -> Void
    private let onEditProfile: (Profile) -> Void
    private let onCancel: (() -> Void)?

    @State private var isEditing = false
    @Environment(\.themePalette) private var palette

    public init(
        profiles: [Profile],
        activeProfileID: String?,
        title: String = "Who's watching?",
        onSelect: @escaping (Profile) -> Void,
        onAddProfile: @escaping () -> Void,
        onEditProfile: @escaping (Profile) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.title = title
        self.onSelect = onSelect
        self.onAddProfile = onAddProfile
        self.onEditProfile = onEditProfile
        self.onCancel = onCancel
    }

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 56)]

    public var body: some View {
        VStack(spacing: 48) {
            Text(isEditing ? "Manage Profiles" : title)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)

            LazyVGrid(columns: columns, spacing: 56) {
                ForEach(profiles) { profile in
                    ProfileTile(
                        profile: profile,
                        isActive: profile.id == activeProfileID,
                        isEditing: isEditing
                    ) {
                        if isEditing { onEditProfile(profile) } else { onSelect(profile) }
                    }
                }
                AddProfileTile(action: onAddProfile)
            }
            .padding(.horizontal, 80)

            HStack(spacing: 24) {
                Button(isEditing ? "Done" : "Edit Profiles") {
                    isEditing.toggle()
                }
                if let onCancel {
                    Button("Cancel", action: onCancel)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 80)
    }
}

/// A single selectable/editable profile tile: avatar symbol on a colored disc
/// plus the profile name, with a tvOS focus scale + an "active"/"edit" badge.
private struct ProfileTile: View {
    let profile: Profile
    let isActive: Bool
    let isEditing: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.themePalette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(ProfileTileColor.color(for: profile))
                    Image(systemName: profile.avatarSymbol)
                        .font(.system(size: 96, weight: .semibold))
                        .foregroundStyle(.white)
                    if isEditing {
                        Circle()
                            .fill(.black.opacity(0.45))
                        Image(systemName: "pencil")
                            .font(.system(size: 64, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 220, height: 220)
                .overlay(alignment: .topTrailing) {
                    if isActive && !isEditing {
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

/// The trailing "Add Profile" tile shown after the profiles.
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
