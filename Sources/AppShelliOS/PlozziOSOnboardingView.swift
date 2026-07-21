#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

/// iOS/iPadOS first-run onboarding entry — the branded welcome + "how do you want
/// to get started" screen, mirroring the tvOS onboarding's first page (server
/// picker + "set up from another device") rather than a bare empty Home tab.
/// Shown by PlozziOSRootView whenever there are no accounts yet.
@MainActor
struct PlozziOSOnboardingView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    @State private var showAddServer = false
    @State private var showReceive = false
    @State private var showAddShare = false

    var body: some View {
        ZStack {
            AppBackground(palette: palette)
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: geo.size.height * 0.12)
                        header
                        Spacer(minLength: 40)
                        options
                        Spacer(minLength: 40)
                    }
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .frame(minHeight: geo.size.height)
                }
            }
        }
        .fullScreenCover(isPresented: $showAddServer) {
            AddServerView(appModel: appModel)
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
        VStack(spacing: 20) {
            Image("PlozzLogo")
                .resizable().scaledToFit()
                .frame(width: 96, height: 96)
            VStack(spacing: 10) {
                Text("Welcome to Plozz")
                    .font(.largeTitle.bold())
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)
                Text("Connect your media server to start watching — or bring your setup over from a device you’ve already signed in.")
                    .font(.body)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var options: some View {
        VStack(spacing: 14) {
            Button {
                showAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                showReceive = true
            } label: {
                Label("Set Up from Another Device", systemImage: "qrcode")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                showAddShare = true
            } label: {
                Label("Add Network Share", systemImage: "externaldrive.badge.plus")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .tint(palette.secondaryText)
        }
    }
}
#endif
