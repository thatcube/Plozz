#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// The shared bordered container that groups a checkmark list in the Settings
/// detail pane — the same treatment as the Customize Home "Rows on Home" cards,
/// so every checkmark section (Theme, Display Size, Music Player style, Circadian
/// options, …) reads as one grouped box. ``SettingsOptionList`` / ``SettingsCheckList``
/// wrap themselves in it by default; pass `bordered: false` when the list already
/// sits inside another container (e.g. a Customize Home group card) to avoid a
/// double border. Matches `HomeRowsGroupCard`'s corner/fill/stroke + 22pt inset so
/// the focus cards bleed identically.
struct SettingsCheckGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.vertical, 10)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.card, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}

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
    /// Wrap the list in the shared bordered container. Default `true`; pass
    /// `false` when the list already sits inside another container.
    var bordered: Bool = true
    let title: (Option) -> String

    @FocusState private var focusedOption: Option?

    private var list: some View {
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
    }

    var body: some View {
        Group {
            if bordered {
                SettingsCheckGroup { list }
            } else {
                list
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
/// Used by the Customize Home screen (and Your Servers & Libraries) to pick which
/// rows / libraries are on. Reuses ``SettingsCheckableRow`` so the checkmark and
/// focus card match Display Size / Theme exactly (maintainer's "share checkmarks"
/// direction), but defaults to `.secondary` prominence: these lists are the
/// **children** of a master toggle, so they read a step lighter than the
/// primary single-select pickers.
struct SettingsCheckList<Option: Hashable & Identifiable>: View {
    let options: [Option]
    var title: (Option) -> String
    var subtitle: (Option) -> String? = { _ in nil }
    var icon: (Option) -> String? = { _ in nil }
    /// Per-option enablement. A `false` row is dimmed and non-focusable (e.g. a
    /// source that depends on an integration that isn't configured yet).
    var isEnabled: (Option) -> Bool = { _ in true }
    /// Wrap the list in the shared bordered container. Default `true`; pass
    /// `false` when the list already sits inside another container (e.g. a
    /// Customize Home group card that provides its own border + header).
    var bordered: Bool = true
    /// Row weight. Defaults to `.secondary` because a multi-select list is a
    /// sub-section under a master toggle; override to `.primary` for a rare
    /// top-level multi-select.
    var prominence: SettingsRowProminence = .secondary
    /// Pass `false` when the list sits inside a bordered card so its rows' focus
    /// cards nest concentrically with the card instead of hugging its border.
    var flushLeading: Bool = true
    var isChecked: (Option) -> Bool
    var onToggle: (Option) -> Void

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                SettingsCheckableRow(
                    title: title(option),
                    subtitle: subtitle(option),
                    icon: icon(option),
                    isChecked: isChecked(option),
                    isEnabled: isEnabled(option),
                    prominence: prominence,
                    flushLeading: flushLeading,
                    action: { onToggle(option) }
                )
            }
        }
    }

    var body: some View {
        if bordered {
            SettingsCheckGroup { list }
        } else {
            list
        }
    }
}

#endif
