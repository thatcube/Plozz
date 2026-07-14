#if canImport(SwiftUI)
import CoreUI
import Foundation
import SwiftUI

/// The single "Local media" entry point. Hosts the ONE unified add-a-media-share
/// flow (`UnifiedAddShareView`) for every transport — SMB, WebDAV (real), and
/// NFS/SFTP (dummy-wired, "coming soon") — so onboarding never fragments into a
/// screen per transport. Discovery is box-centric and multi-transport; the user
/// picks a device or types an address, then one Connect form collects protocol,
/// port, and credentials before browsing to a share/folder.
struct AddMediaShareView: View {
    let isPageReady: Bool
    let onBack: () -> Void
    let onSMBConfigured: (ShareDraft) -> Void
    let onWebDAVConfigured: (WebDAVShareConfiguration) -> Void
    var onMediaShareConfigured: (MediaShareOnboardingResult) -> Void = { _ in }

    var body: some View {
        UnifiedAddShareView(
            isPageReady: isPageReady,
            onBack: onBack,
            onSMBConfigured: onSMBConfigured,
            onWebDAVConfigured: onWebDAVConfigured,
            onMediaShareConfigured: onMediaShareConfigured
        )
    }
}
#endif
