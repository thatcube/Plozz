#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// A vertical, checkable list of **mutually-exclusive** options for the Settings
/// detail pane: one focusable row per option (leading icon, title, trailing
/// checkmark on the current selection).
///
/// The horizontal counterpart is ``SettingsOptionPicker`` (the "season tab" pill
/// strip). For **independent** (multi-select) choices — pick any combination —
/// use ``SettingsCheckList``. All three share ``SettingsCheckableRow`` so the
/// checkmark + focus-card look is identical.
struct SettingsOptionList<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var icon: (Option) -> String? = { _ in nil }
    /// Called with `true` when any row in the list gains focus and `false` when
    /// focus leaves the list entirely (live-preview hook — Circadian Mode).
    var onFocusChange: ((Bool) -> Void)? = nil
    let title: (Option) -> String

    @FocusState private var focusedOption: Option?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { option in
                SettingsCheckableRow(
                    title: title(option),
                    icon: icon(option),
                    isChecked: selection == option,
                    action: { selection = option }
                )
                .focused($focusedOption, equals: option)
            }
        }
        .onChange(of: focusedOption) { _, focused in
            onFocusChange?(focused != nil)
        }
    }
}

/// A vertical, checkable list of **independent** options — each row toggles on/off
/// on its own (multi-select), unlike ``SettingsOptionList``'s single selection.
///
/// Used by the Customize Home screen to pick which rows appear on Home. Reuses
/// ``SettingsCheckableRow`` so the checkmark and focus card match Display Size /
/// Theme exactly (maintainer's "share checkmarks" direction).
struct SettingsCheckList<Option: Hashable & Identifiable>: View {
    let options: [Option]
    var title: (Option) -> String
    var subtitle: (Option) -> String? = { _ in nil }
    var icon: (Option) -> String? = { _ in nil }
    var isChecked: (Option) -> Bool
    var onToggle: (Option) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                SettingsCheckableRow(
                    title: title(option),
                    subtitle: subtitle(option),
                    icon: icon(option),
                    isChecked: isChecked(option),
                    action: { onToggle(option) }
                )
            }
        }
    }
}

#endif
