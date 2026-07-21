#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

/// iOS/iPadOS first-run onboarding — mirrors the tvOS entry: the branded Plozz
/// logo + "Free forever and open source." tagline, a direct provider chooser
/// (Jellyfin / Plex / Emby / Media Share), and a "Set up from another device"
/// button. Shown by PlozziOSRootView whenever there are no accounts yet.
@MainActor
struct PlozziOSOnboardingView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    @State private var addProvider: OnboardingProvider?
    @State private var showReceive = false
    @State private var showAddShare = false

    var body: some View {
        ZStack {
            AppBackground(palette: palette)
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 32) {
                        Spacer(minLength: geo.size.height * 0.08)
                        header
                        providerList
                        receiveButton
                        Spacer(minLength: 32)
                    }
                    .frame(maxWidth: 500)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .frame(minHeight: geo.size.height)
                }
            }
        }
        .fullScreenCover(item: $addProvider) { wrapped in
            AddServerView(appModel: appModel, initialProvider: wrapped.kind)
        }
        .fullScreenCover(isPresented: $showReceive) {
            PlozziOSSyncSetupReceiveView(appModel: appModel) { showReceive = false }
        }
        .fullScreenCover(isPresented: $showAddShare) {
            NavigationStack {
                PlozziOSAddShareView(appModel: appModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAddShare = false }
                        }
                    }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("PlozzLogo")
                .resizable().scaledToFit()
                .frame(width: 88, height: 88)
            Image("PlozzWordmark")
                .resizable().scaledToFit()
                .frame(height: 38)
                .foregroundStyle(palette.primaryText)
            Text("Free forever and open source.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
        }
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            providerRow(.jellyfin)
            divider
            providerRow(.plex)
            divider
            providerRow(.emby)
            divider
            providerRow(.mediaShare)
        }
        .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle().fill(palette.cardBorder).frame(height: 1)
    }

    private func providerRow(_ provider: ProviderKind) -> some View {
        Button {
            if provider == .mediaShare {
                showAddShare = true
            } else {
                addProvider = OnboardingProvider(kind: provider)
            }
        } label: {
            HStack(spacing: 16) {
                ProviderBrandMark(provider: provider, size: 40)
                Text(provider.displayName)
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var receiveButton: some View {
        Button {
            showReceive = true
        } label: {
            Label("Set Up from Another Device", systemImage: "qrcode")
                .font(.headline)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(palette.accent)
    }
}

/// Identifiable wrapper so a chosen provider can drive `.fullScreenCover(item:)`.
private struct OnboardingProvider: Identifiable {
    let kind: ProviderKind
    var id: String { kind.rawValue }
}
#endif
