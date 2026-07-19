import SwiftUI
import CoreModels

/// Plozz — iOS foundation spike (Part A).
///
/// A deliberately THIN iOS/iPadOS app whose only job is to prove that the
/// shared, platform-neutral core (CoreModels, CoreNetworking, the providers,
/// media transports, and metadata/ratings services) compiles and links on iOS.
/// It renders a blank placeholder and links NONE of the tvOS UI/playback
/// modules. Real iOS UI is future work (Part B).
@main
struct PlozziOSApp: App {
    var body: some Scene {
        WindowGroup {
            SpikeRootView()
        }
    }
}

private struct SpikeRootView: View {
    // Touch a shared-core API at runtime so the linker keeps the module and we
    // prove it actually loads on iOS (not just links). MediaCapabilities lives in
    // CoreModels and probes VideoToolbox/AVFoundation behind platform gates.
    private let capabilities = MediaCapabilities.detected()

    var body: some View {
        VStack(spacing: 12) {
            Text("Plozz")
                .font(.largeTitle.bold())
            Text("iOS foundation spike — shared core linked")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("HEVC: \(capabilities.supportsHEVC ? "yes" : "no") · "
                + "max audio ch: \(capabilities.maxOutputChannels)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
