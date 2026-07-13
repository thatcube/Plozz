#if canImport(SwiftUI)
import CoreUI
import Foundation
import SwiftUI

/// Lets the user pick which kind of local media share to add — **SMB** (a NAS
/// on the LAN) or **WebDAV** (an HTTP file server) — then hosts the matching
/// flow. Slots in where the account chooser used to push `AddShareView`
/// directly, so SMB behaves exactly as before and WebDAV joins as a sibling.
struct AddMediaShareView: View {
    let isPageReady: Bool
    let onBack: () -> Void
    let onSMBConfigured: (ShareDraft) -> Void
    let onWebDAVConfigured: (WebDAVShareConfiguration) -> Void

    enum Kind: Hashable { case smb, webDAV }

    @State private var kind: Kind?
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case back, smb, webDAV }

    var body: some View {
        switch kind {
        case .none:
            chooser
        case .smb:
            AddShareView(
                isPageReady: isPageReady,
                onBack: { kind = nil },
                onConfigured: onSMBConfigured
            )
        case .webDAV:
            AddWebDAVShareView(
                onBack: { kind = nil },
                onConfigured: onWebDAVConfigured
            )
        }
    }

    private var chooser: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 20) {
                        Button(action: onBack) {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .buttonStyle(.bordered)
                        .focused($focusedField, equals: .back)
                        OnboardingHeader(
                            "Add a Media Share",
                            subtitle: "Point Plozz at a folder on your network."
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 40)

                    HStack(spacing: 28) {
                        kindCard(
                            .smb,
                            title: "SMB",
                            detail: "A NAS or shared folder on your local network.",
                            icon: "externaldrive.connected.to.line.below.fill",
                            field: .smb
                        )
                        kindCard(
                            .webDAV,
                            title: "WebDAV",
                            detail: "An HTTP(S) file server such as Nextcloud or Apache.",
                            icon: "network",
                            field: .webDAV
                        )
                    }
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 48)
                .padding(.vertical, 32)
                .padding(.top, proxy.safeAreaInsets.top)
                .padding(.bottom, proxy.safeAreaInsets.bottom)
            }
            .scrollClipDisabled()
            .ignoresSafeArea(.container, edges: .vertical)
        }
        .defaultFocus($focusedField, .smb)
        .onExitCommand(perform: onBack)
        .onAppear { focusedField = .smb }
    }

    private func kindCard(
        _ kindValue: Kind,
        title: String,
        detail: String,
        icon: String,
        field: Field
    ) -> some View {
        Button { kind = kindValue } label: {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(title).font(.title2.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
            .padding(28)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
        .focused($focusedField, equals: field)
    }
}
#endif
