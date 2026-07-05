#if canImport(SwiftUI)
import SwiftUI

/// A compact, one-line settings row: a fixed-width title column on the leading
/// edge and an arbitrary control (pills, a stepper, a menu, a toggle…) trailing
/// it. Stacking a header label *above* every control eats a lot of vertical
/// space in the 10-foot UI; laying the label beside the control instead lets a
/// whole settings panel breathe on one screen.
///
/// The title column is a fixed width so controls line up down the panel. Pass an
/// optional `subtitle` for a secondary line of helper text under the title.
/// Pair the trailing slot with ``SettingsOptionPicker`` for the common
/// "label + pills" row.
public struct LabeledSettingRow<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let labelWidth: CGFloat
    private let trailingAlignment: Alignment
    private let trailing: Trailing

    /// - Parameters:
    ///   - title: The leading label.
    ///   - subtitle: Optional helper text shown under the title.
    ///   - labelWidth: Width of the fixed title column so rows align. Defaults to
    ///     a value tuned for the Settings panels.
    ///   - trailingAlignment: How the trailing control sits in its column.
    ///     Defaults to `.leading` (hugs the label). Pass `.trailing` for dropdown
    ///     "button menus" so they align to the right edge of the row.
    ///   - trailing: The control shown to the right of the label.
    public init(
        _ title: String,
        subtitle: String? = nil,
        labelWidth: CGFloat = 240,
        trailingAlignment: Alignment = .leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.labelWidth = labelWidth
        self.trailingAlignment = trailingAlignment
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: labelWidth, alignment: .leading)

            trailing
                .frame(maxWidth: .infinity, alignment: trailingAlignment)
        }
    }
}

#endif
