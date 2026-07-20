#if canImport(SwiftUI)
import SwiftUI

public struct SettingsSectionGroup<Content: View, Footer: View>: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.displayScale) private var displayScale
    private let title: String?
    private let content: Content
    private let footer: Footer

    public init(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
            }

            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews) { subview in
                        subview
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        if subview.id != subviews.last?.id {
                            Rectangle()
                                .fill(palette.cardOpaqueBorder)
                                .frame(height: hairlineWidth)
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
            #if os(tvOS)
            .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
            #else
            .toggleStyle(.switch)
            .tint(ThemePalette.brandBlue)
            #endif
            .background(
                palette.cardOpaqueSurface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        palette.cardOpaqueBorder,
                        lineWidth: hairlineWidth
                    )
                    .allowsHitTesting(false)
            }

            footer
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        #if !os(tvOS)
        .listRowSeparator(.hidden)
        #endif
    }

    private var hairlineWidth: CGFloat {
        1 / max(displayScale, 1)
    }
}

public extension SettingsSectionGroup where Footer == EmptyView {
    init(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}
#endif
