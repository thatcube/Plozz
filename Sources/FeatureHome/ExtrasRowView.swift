#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

struct ExtrasRowView: View {
    let state: LoadState<[MediaExtra]>
    var leadingInset: CGFloat = PlozzTheme.Metrics.screenPadding
    var spoilerSettings: SpoilerSettings = .default
    var onFocusEntered: (() -> Void)?
    var onSelect: (MediaExtra) -> Void
    var onRetry: () -> Void

    @Environment(\.plozzMetrics) private var metrics
    @State private var showsLoadingPlaceholders = false

    var body: some View {
        content
            .padding(.top, -metrics.railTopPadding)
            .padding(.bottom, -metrics.railVerticalPadding)
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
            MediaRowView(
                title: Text("Extras"),
                items: extras.map(\.item),
                style: .landscape,
                spoilerSettings: spoilerSettings,
                leadingInset: leadingInset,
                onFocusEntered: onFocusEntered,
                statusCue: { item in
                    extras.first(where: { $0.item.stablePresentationID == item.stablePresentationID })?
                        .kind.displayName
                },
                playsOnSelect: true,
                onSelect: { item in
                    guard let extra = extras.first(where: {
                        $0.item.stablePresentationID == item.stablePresentationID
                    }) else { return }
                    onSelect(extra)
                }
            )
        case .loading where showsLoadingPlaceholders:
            ExtrasLoadingRow(leadingInset: leadingInset)
        case .failed(let error):
            ExtrasFailureRow(
                message: error.userMessage,
                leadingInset: leadingInset,
                onRetry: onRetry
            )
        default:
            EmptyView()
        }
    }
}

private struct ExtrasLoadingRow: View {
    let leadingInset: CGFloat

    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
            Text("Extras")
                .font(PlozzRailTitle.font(
                    sectionHeaderFontSize: metrics.sectionHeaderFontSize
                ))
                .padding(.leading, leadingInset)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.cardSpacing) {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonCardView(style: .landscape)
                            .frame(width: metrics.landscapeWidth)
                    }
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, metrics.railShadowClearance)
            }
            .padding(.top, metrics.railTopClearanceOffset)
            .padding(.bottom, metrics.railBottomClearanceOffset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExtrasFailureRow: View {
    let message: LocalizedStringResource
    let leadingInset: CGFloat
    let onRetry: () -> Void

    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extras")
                .font(PlozzRailTitle.font(
                    sectionHeaderFontSize: metrics.sectionHeaderFontSize
                ))
            Text(message)
                .foregroundStyle(.secondary)
            Button("Try Again", action: onRetry)
        }
        .padding(.leading, leadingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
