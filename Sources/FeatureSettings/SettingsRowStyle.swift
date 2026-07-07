#if canImport(SwiftUI)
import SwiftUI
import CoreUI

// The shared, theme-aware list-row focus style (`SettingsFocusButtonStyle`), its
// `SettingsRowSize`, the `settingsRowIsFocused` / `settingsRowFocusForeground`
// environment values, and the `.settingsRowSecondary()/Icon()/GreenIndicator()`
// helpers now live in CoreUI (`SettingsRowFocusStyle.swift`) so other modules —
// e.g. the music rails' "See All" — can focus identically instead of drifting
// from a private copy. The row body + switch toggle below still consume them via
// the `import CoreUI` above.

// MARK: - Shared row body (one- or two-line)

private extension VerticalAlignment {
    /// Aligns the leading icon to the vertical center of the *title line* rather
    /// than the whole title+subtitle block, so on two-line rows the icon pairs
    /// with the title instead of floating between the two lines. On one-line rows
    /// the title *is* the block, so this collapses to a plain centered icon.
    enum RowTitleIcon: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat {
            d[VerticalAlignment.center]
        }
    }
    static let rowTitleIcon = VerticalAlignment(RowTitleIcon.self)
}

/// The shared body of a Settings list row: a leading icon, a primary `title`,
/// an optional SECOND line beneath the title, and a trailing accessory.
///
/// Wrap it in a `NavigationLink` or `Button` and apply
/// ``SettingsFocusButtonStyle`` to turn it into a live nav / toggle row — the
/// two-column shape stays identical whether the second line is descriptive
/// text, a strip of account avatars, or nothing at all, so every row reads as
/// one control family. Leave `secondary` unset for a plain one-line row; pass a
/// view (a subtitle, an avatar strip…) for the two-line variant. The `trailing`
/// slot carries a value + chevron for navigation, or an On/Off word for an
/// in-place toggle.
///
/// Row content adapts to focus automatically: pair inner text with
/// `.settingsRowSecondary()` so it inverts against the focus card.
struct SettingsRowLabel<Secondary: View, Trailing: View>: View {
    private let icon: String?
    private let assetIcon: String?
    private let title: String
    private let secondary: Secondary
    private let trailing: Trailing

    init(
        icon: String?,
        assetIcon: String? = nil,
        title: String,
        @ViewBuilder secondary: () -> Secondary = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.assetIcon = assetIcon
        self.title = title
        self.secondary = secondary()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 16) {
            // Icon + text share a custom alignment so the icon centers on the
            // TITLE line, not the two-line block. The trailing accessory stays in
            // the outer HStack (default center), so the chevron keeps centering on
            // the full row height.
            HStack(alignment: .rowTitleIcon, spacing: 16) {
                if let assetIcon {
                    // Custom (non–SF Symbol) glyph from the asset catalog. It's
                    // rendered as a TEMPLATE so it inherits the same tint / focus
                    // inversion as the SF Symbols, and sized to ~22pt (the symbols'
                    // optical size) inside the shared 30×30 alignment box so a
                    // full-bleed vector doesn't read heavier than its neighbors.
                    Image(assetIcon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .frame(width: 30, height: 30)
                        .settingsRowIcon()
                        .alignmentGuide(.rowTitleIcon) { $0[VerticalAlignment.center] }
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 30, height: 30)
                        .settingsRowIcon()
                        .alignmentGuide(.rowTitleIcon) { $0[VerticalAlignment.center] }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.callout.weight(.medium))
                        .alignmentGuide(.rowTitleIcon) { $0[VerticalAlignment.center] }
                    secondary
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}
#endif
