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
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, 8)
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
                                .fill(palette.separator)
                                .frame(height: hairlineWidth)
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .buttonStyle(SettingsSectionButtonStyle())
            #if os(tvOS)
            .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
            #else
            .toggleStyle(SettingsTouchSwitchToggleStyle())
            #endif
            .settingsGroupSurface(cornerRadius: 18)

            footer
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .padding(.top, 8)
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

private struct SettingsSectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
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
