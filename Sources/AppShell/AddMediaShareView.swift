#if canImport(SwiftUI)
import CoreUI
import Foundation
import SwiftUI

/// The single "Local media" entry point. There is NO SMB-vs-WebDAV pick: the
/// user sees servers discovered on the network (SMB today) and one address
/// field. Typing an address auto-detects the transport (`MediaShareRouteDetector`)
/// and routes SMB → the share picker or WebDAV → its credential/folder flow, so
/// the user never chooses or names a protocol.
struct AddMediaShareView: View {
    let isPageReady: Bool
    let onBack: () -> Void
    let onSMBConfigured: (ShareDraft) -> Void
    let onWebDAVConfigured: (WebDAVShareConfiguration) -> Void

    /// Non-nil when the typed address detected as WebDAV — hosts the WebDAV flow
    /// pre-seeded with the resolved URL. Otherwise the SMB discovery + address
    /// screen is shown.
    @State private var webDAVAddress: String?

    var body: some View {
        if let webDAVAddress {
            AddWebDAVShareView(
                onBack: { self.webDAVAddress = nil },
                onConfigured: onWebDAVConfigured,
                initialAddress: webDAVAddress
            )
        } else {
            AddShareView(
                isPageReady: isPageReady,
                onBack: onBack,
                onConfigured: onSMBConfigured,
                onWebDAVDetected: { url in webDAVAddress = url.absoluteString }
            )
        }
    }
}
#endif
