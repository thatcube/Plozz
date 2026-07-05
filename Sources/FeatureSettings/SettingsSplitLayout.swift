#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// One row in a Settings master/detail split. The left list shows the row's
/// `title`; focusing it live-updates the right detail pane, which renders the
/// row's `description` and the row's existing `detail` control.
///
/// `id` is stable so focus survives sub-rows inserting/removing (a per-type
/// toggle revealing Movies/TV/Anime). Set `indented` for those revealed
/// children so they read as nested under their parent toggle.
struct SettingsSplitRow: Identifiable {
    let id: String
    let title: String
    let description: String?
    let indented: Bool
    let detail: () -> AnyView

    init<Detail: View>(
        id: String,
        title: String,
        description: String? = nil,
        indented: Bool = false,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.indented = indented
        self.detail = { AnyView(detail()) }
    }
}

/// A titled group of rows in the master list. `header` uses the shared compact
/// uppercase Settings section-header treatment.
struct SettingsSplitSection: Identifiable {
    let id: String
    let header: String?
    let rows: [SettingsSplitRow]

    init(id: String, header: String? = nil, rows: [SettingsSplitRow]) {
        self.id = id
        self.header = header
        self.rows = rows
    }
}

/// A native tvOS master/detail layout for Level-2 settings pages.
///
/// LEFT (master): a focusable vertical list of setting *names* grouped under
/// section headers. The list owns focus; moving focus up/down **live-updates**
/// the detail pane via `selectedRowID`.
///
/// RIGHT (detail): a `.focusSection()` pane showing the focused row's
/// description and its existing control (a `SettingsOptionPicker`, `Toggle`,
/// language `Menu`, …). Press **right** (or Select) to move focus into the
/// control; **left / Menu** returns to the list. This mirrors Apple's own
/// Settings/Music master-detail choreography on tvOS.
///
/// `sections` is expected to be a *computed* value in the host page, so
/// flipping a toggle in the detail pane recomputes the list (revealing or
/// hiding indented sub-rows) on the next render.
struct SettingsSplitLayout: View {
    /// The page's own name (matches the parent nav row that opened it, e.g.
    /// "Appearance") — shown as the single header atop the left list.
    let title: String
    let sections: [SettingsSplitSection]

    @State private var selectedRowID: String?
    @FocusState private var focusedRow: String?
    /// Scopes the master list so the selected row can be its *preferred* default
    /// focus. Pressing left out of the detail pane (or returning from a pushed
    /// page) then lands back on the row the user came in from, rather than the
    /// geometrically-nearest row.
    @Namespace private var masterScope
    /// True while focus lives in the detail pane. While set, every master row
    /// *except* the selected one is pulled out of the focus order — so a
    /// left-press out of a control has exactly one place to land (the row you
    /// came in from), with no geometrically-nearer row to steal it.
    @State private var focusInDetail = false

    private var allRows: [SettingsSplitRow] { sections.flatMap(\.rows) }
    private var allRowIDs: [String] { allRows.map(\.id) }

    /// The row currently mirrored in the detail pane. Falls back to the first
    /// row so the pane is never blank (e.g. before first focus, or right after
    /// the selected row was removed).
    private var selectedRow: SettingsSplitRow? {
        allRows.first { $0.id == selectedRowID } ?? allRows.first
    }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 60) {
                masterList
                    .frame(width: max(280, geo.size.width * 0.40 - 160), alignment: .leading)
                    // Generous top inset so the nav list starts level with the
                    // detail panel's content (which the panel pads down to match),
                    // even though the panel itself now runs full height.
                    .padding(.top, 26)

                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.leading, PlozzTheme.Metrics.screenPadding)
        }
        .ignoresSafeArea(edges: .trailing)
        .onAppear {
            if selectedRowID == nil { selectedRowID = allRowIDs.first }
        }
        // If the selected row vanished (a revealed sub-row was hidden again),
        // fall back to the first row so the pane keeps showing something valid.
        .onChange(of: allRowIDs) { _, ids in
            if let selected = selectedRowID, !ids.contains(selected) {
                selectedRowID = ids.first
            }
        }
    }

    // MARK: - Master list (left)

    private var masterList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                // One page header at the top, always in sync with the nav row the
                // user came from. Per-section subheaders are intentionally omitted.
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)

                ForEach(sections) { section in
                    ForEach(section.rows) { row in
                        masterRow(row)
                            .focused($focusedRow, equals: row.id)
                            .prefersDefaultFocus(selectedRowID == row.id, in: masterScope)
                            .id(row.id)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
        // Moving focus up/down the list drives the live preview on the right.
        // When focus leaves the list it has gone into the detail pane: park the
        // list (so the only way back is the row we came from). When it returns,
        // unpark and resume the live preview.
        .onChange(of: focusedRow) { _, newID in
            if let newID {
                focusInDetail = false
                selectedRowID = newID
            } else {
                focusInDetail = true
            }
        }
        .focusScope(masterScope)
        .focusSection()
    }

    private func masterRow(_ row: SettingsSplitRow) -> some View {
        Button {
            // Tapping a row just pins it as the live selection; press right to
            // drill focus into its control in the detail pane. A tap is NOT a
            // focus-section flip, so animating the detail cross-fade here is safe
            // (unlike the focus-driven path, which must stay instant — see the
            // detail pane's note on the removed `.animation(value: selectedRowID)`).
            withAnimation(.easeInOut(duration: 0.18)) { selectedRowID = row.id }
        } label: {
            SettingsMasterRowLabel(row: row, isSelected: selectedRowID == row.id)
        }
        .buttonStyle(SettingsFocusButtonStyle())
        // While editing in the detail pane, take every other row out of the
        // focus order so a left-press can only return to where we came in from.
        .disabled(focusInDetail && selectedRowID != row.id)
    }

    // MARK: - Detail pane (right)

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let row = selectedRow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title)
                            .font(.title3.weight(.semibold))
                        if let description = row.description {
                            Text(description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    row.detail()
                        .toggleStyle(SettingsSwitchToggleStyle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 56)
            .padding(.bottom, 48)
            .padding(.leading, 80)
            .padding(.trailing, 120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Full-height detail panel, separated from the master list by a single
        // left-edge divider instead of an enclosing card border. The fill + divider
        // ignore the vertical safe area so the panel reaches the very top and bottom
        // of the page; the scrolling content stays within the safe-area frame.
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
            }
            .ignoresSafeArea(edges: .vertical)
        }
        // The detail pane's Text/description views are REPLACED whenever
        // `selectedRowID` changes — and that changes as focus moves in the master
        // list (see `onChange(of: focusedRow)`). Animating that hierarchy swap on
        // a focus-driven change is the tvOS focus-flip crash pattern
        // (`-[…LocalizedTextStorage setToViewXFlippedScreenShot:]`): the focus
        // engine snapshots views for its flip while SwiftUI is tearing down/re-
        // inserting the animated Text, freeing a view UIKit still references.
        // So the detail pane updates INSTANTLY as focus moves (no `.animation`
        // here). A tap that pins a row still animates via its `withAnimation`.
        .focusSection()
    }
}

/// One left-list row. Adds a trailing chevron (it always drills into a control)
/// and a *persistent* accent selection treatment so the row mirrored in the
/// detail pane stays visibly marked even while focus is over in the detail
/// (where the user is editing its control). The white inverted focus card takes
/// over the moment the row itself is focused, so selection and focus never
/// fight: chevroned text-rows on the left read as navigation, switch/pill
/// controls on the right read as controls.
private struct SettingsMasterRowLabel: View {
    let row: SettingsSplitRow
    let isSelected: Bool
    @Environment(\.settingsRowIsFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    /// Accent selection only shows when this row is the live selection AND the
    /// list does not currently hold focus (focus is in the detail pane).
    private var showSelection: Bool { isSelected && !isFocused }

    var body: some View {
        HStack(spacing: 14) {
            if row.indented {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 26)
            }
            Text(row.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 12)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(showSelection ? palette.accent.opacity(0.16) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if showSelection {
                Capsule(style: .continuous)
                    .fill(palette.accent)
                    .frame(width: 4, height: 24)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A master switch that gates a group of dependent controls inside a single
/// detail pane — the iOS "form section" idiom. The switch sits on top; flipping
/// it on reveals an optional uppercase subhead and the `content` (e.g. the
/// per-content-type Movies / TV Shows / Anime rows) directly beneath it.
///
/// This replaces dynamically inserting indented child rows into the *master*
/// list (which made the left index feel unstable and mis-indented). Children
/// now live where they belong — inside their parent setting's detail — and the
/// master list keeps one stable row per setting.
struct SettingsRevealSection<Content: View>: View {
    @Binding var isOn: Bool
    let masterLabel: String
    var revealedHeader: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle(masterLabel, isOn: $isOn)

            if isOn {
                VStack(alignment: .leading, spacing: 16) {
                    if let revealedHeader {
                        Text(revealedHeader)
                            .font(.subheadline.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .padding(.horizontal, 4)
                    }
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }
}
#endif
