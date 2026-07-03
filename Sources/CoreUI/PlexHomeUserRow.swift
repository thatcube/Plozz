#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A Plex Home user's avatar circle, sized to `size` pt. Renders the user's
/// real Plex `thumb` when reachable, falling back to their initial on a Plex-
/// tinted tile. Shared so every Plex-user surface (Settings picker, first-run
/// onboarding picker) shows an identical avatar.
public struct PlexHomeUserAvatar: View {
    private let user: PlexHomeUser
    private let size: CGFloat

    public init(user: PlexHomeUser, size: CGFloat = 52) {
        self.user = user
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(ProviderBrandMark.brandTint(.plex).opacity(0.18))
            if let url = user.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        initial
                    }
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ProviderBrandMark.brandTint(.plex).opacity(0.45), lineWidth: 1.5))
    }

    private var initial: some View {
        Text(String(user.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(ProviderBrandMark.brandTint(.plex))
    }
}

/// The label content for a single Plex Home user row — a 52pt avatar, the
/// user's name, and inline badges (Account owner / Restricted / PIN required),
/// plus an optional trailing selection checkmark. Designed to sit inside a
/// `Button { } .buttonStyle(SettingsFocusButtonStyle())`, so the Settings Plex-
/// user picker and the first-run onboarding picker render identically.
public struct PlexHomeUserRow: View {
    public enum Accessory: Equatable, Sendable {
        /// No trailing accessory.
        case none
        /// A green checkmark indicating this is the active selection.
        case selected
    }

    private let user: PlexHomeUser
    private let showsOwnerBadge: Bool
    private let accessory: Accessory

    public init(
        user: PlexHomeUser,
        showsOwnerBadge: Bool = false,
        accessory: Accessory = .none
    ) {
        self.user = user
        self.showsOwnerBadge = showsOwnerBadge
        self.accessory = accessory
    }

    public var body: some View {
        HStack(spacing: 16) {
            PlexHomeUserAvatar(user: user, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(user.name).font(.headline)

                    if showsOwnerBadge {
                        Text("Account owner")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(ProviderBrandMark.brandTint(.plex).opacity(0.18)))
                            .foregroundStyle(ProviderBrandMark.brandTint(.plex))
                    }

                    if user.isRestricted {
                        Text("Restricted")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }

                    if user.requiresPIN {
                        // Lock + "PIN" together — the lock alone read as
                        // unclear; keep it focus-adaptive so it stays legible
                        // on the inverted (focused) card.
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                            Text("PIN")
                        }
                        .font(.caption2.weight(.semibold))
                        .settingsRowSecondary()
                        .accessibilityLabel("PIN required")
                    }
                }

                if user.isRestricted {
                    Text("Limited content set by the account owner.")
                        .font(.footnote)
                        .settingsRowSecondary()
                }
            }

            Spacer()

            if accessory == .selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .settingsRowGreenIndicator()
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }
}
#endif
