#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

struct PlozziOSExtrasSection: View {
    let state: LoadState<[MediaExtra]>
    let inset: CGFloat
    let onSelect: (MediaExtra) -> Void
    let onRetry: () -> Void

    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 220
    @State private var showsLoadingPlaceholders = false

    var body: some View {
        content
            .task(id: state.diagnosticName) {
                showsLoadingPlaceholders = false
                guard state.isLoading else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, state.isLoading else { return }
                showsLoadingPlaceholders = true
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loaded(let extras) where !extras.isEmpty:
            PlozziOSExtrasRail(
                extras: extras,
                inset: inset,
                cardWidth: cardWidth,
                onSelect: onSelect
            )
        case .loading where showsLoadingPlaceholders:
            PlozziOSExtrasLoadingRail(inset: inset, cardWidth: cardWidth)
        case .failed(let error):
            PlozziOSExtrasFailure(
                message: error.userMessage,
                inset: inset,
                onRetry: onRetry
            )
        default:
            EmptyView()
        }
    }
}

private struct PlozziOSExtrasRail: View {
    let extras: [MediaExtra]
    let inset: CGFloat
    let cardWidth: CGFloat
    let onSelect: (MediaExtra) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extras")
                .font(.title3.weight(.bold))
                .padding(.horizontal, inset)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(extras) { extra in
                        Button {
                            onSelect(extra)
                        } label: {
                            PlozziOSPosterCard(
                                item: extra.item,
                                style: .landscape,
                                showsResumeChip: extra.supportsResume
                            )
                            .frame(width: cardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, inset)
            }
            .scrollClipDisabled()
        }
    }
}

private struct PlozziOSExtrasLoadingRail: View {
    let inset: CGFloat
    let cardWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extras")
                .font(.title3.weight(.bold))
                .padding(.horizontal, inset)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        PlozziOSPosterCard(item: nil, style: .landscape)
                            .frame(width: cardWidth)
                    }
                }
                .padding(.horizontal, inset)
            }
            .scrollClipDisabled()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct PlozziOSExtrasFailure: View {
    let message: LocalizedStringResource
    let inset: CGFloat
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extras")
                .font(.title3.weight(.bold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, inset)
    }
}
#endif
