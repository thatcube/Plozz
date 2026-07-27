#if canImport(SwiftUI)
import SwiftUI

public struct SettingsSectionGroup<Content: View, Footer: View>: View {
    @Environment(\.themePalette) private var palette
    private let title: Text?
    private let content: Content
    private let footer: Footer

    /// Section header that is app COPY — the common case, so literals still work.
    public init(
        _ title: LocalizedStringResource? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title.map(Text.init)
        self.content = content()
        self.footer = footer()
    }

    /// Section header that is verbatim CONTENT — e.g. the legal/trademark
    /// attribution sections, whose wording is deliberately not translated.
    public init(
        verbatim title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = Text(verbatim: title)
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                title
                    .font(.footnote.weight(.semibold))
                    .plozzForeground(.secondary)
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
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .buttonStyle(SettingsSectionButtonStyle())
            .labelStyle(SettingsIconLabelStyle())
            #if os(tvOS)
            .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
            #else
            .toggleStyle(SettingsTouchSwitchToggleStyle())
            #endif
            .settingsGroupSurface(cornerRadius: 18)

            footer
                .font(.footnote)
                .plozzForeground(.secondary)
                .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        #if !os(tvOS)
        .listRowSeparator(.hidden)
        #endif
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
        _ title: LocalizedStringResource? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, content: content, footer: { EmptyView() })
    }

    init(
        verbatim title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(verbatim: title, content: content, footer: { EmptyView() })
    }
}
#endif
