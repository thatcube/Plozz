#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// One row in a Settings master/detail split. The left list shows the row's
/// `title` (plus an optional trailing `valueSummary`); focusing it live-updates
/// the right detail pane, which renders the row's `description` and the row's
/// existing `detail` control.
///
/// `id` is stable so focus survives sub-rows inserting/removing (a per-type
/// toggle revealing Movies/TV/Anime). Set `indented` for those revealed
/// children so they read as nested under their parent toggle.
struct SettingsSplitRow: Identifiable {
    let id: String
    let title: String
    let description: String?
    let valueSummary: String?
    let indented: Bool
    /// When true, *entering* this row's detail (pressing right / Select) grows
    /// the pane into a full-bleed, full-height "immersive" editor — the left
    /// index collapses to a slim strip and the detail drops its card chrome, so
    /// a live preview + floating controls can mirror the in-player experience.
    /// Merely navigating past the row in the list still shows the normal compact
    /// preview; expansion is opt-in on enter and collapses on left/Menu.
    let immersive: Bool
    let detail: () -> AnyView

    init<Detail: View>(
        id: String,
        title: String,
        description: String? = nil,
        valueSummary: String? = nil,
        indented: Bool = false,
        immersive: Bool = false,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.valueSummary = valueSummary
        self.indented = indented
        self.immersive = immersive
        self.detail = { AnyView(detail()) }
    }
}

/// Injected into an immersive row's detail so the editor knows whether it is
/// currently *expanded* (focus is inside it) or showing its compact preview.
private struct SettingsDetailExpandedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsDetailExpanded: Bool {
        get { self[SettingsDetailExpandedKey.self] }
        set { self[SettingsDetailExpandedKey.self] = newValue }
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

    /// True while the user has *entered* an immersive row's detail — drives the
    /// index collapse + full-bleed pane transition.
    private var isImmersive: Bool {
        focusInDetail && (selectedRow?.immersive ?? false)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: isImmersive ? 0 : 40) {
                masterList
                    .frame(width: isImmersive ? 108 : max(360, geo.size.width * 0.40),
                           alignment: .leading)
                    .opacity(isImmersive ? 0.55 : 1)

                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, isImmersive ? 0 : PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, isImmersive ? 0 : 24)
            .animation(.easeInOut(duration: 0.30), value: isImmersive)
        }
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
                Text(title)
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                ForEach(sections) { section in
                    if let header = section.header {
                        Text(header)
                            .font(.subheadline.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 22)
                            .padding(.bottom, 4)
                    }

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
            // drill focus into its control in the detail pane.
            selectedRowID = row.id
        } label: {
            SettingsMasterRowLabel(row: row, isSelected: selectedRowID == row.id)
        }
        .buttonStyle(SettingsFocusButtonStyle())
        // While editing in the detail pane, take every other row out of the
        // focus order so a left-press can only return to where we came in from.
        .disabled(focusInDetail && selectedRowID != row.id)
    }

    // MARK: - Detail pane (right)

    @ViewBuilder
    private var detailPane: some View {
        if let row = selectedRow, row.immersive {
            immersiveDetail(row)
        } else {
            standardDetail
        }
    }

    /// An immersive row owns the whole pane: no title/description chrome, no
    /// inner scroll padding. It renders full-bleed and reads
    /// `settingsDetailExpanded` to switch between its compact preview and the
    /// expanded editor. The card corner animates to 0 while expanded so it reads
    /// as a full-height mini-player.
    private func immersiveDetail(_ row: SettingsSplitRow) -> some View {
        let corner: CGFloat = isImmersive ? 0 : PlozzTheme.Metrics.mediumCardCornerRadius
        return row.detail()
            .environment(\.settingsDetailExpanded, isImmersive)
            .toggleStyle(SettingsSwitchToggleStyle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isImmersive ? 0 : 0.08), lineWidth: 1)
            )
            .focusSection()
    }

    private var standardDetail: some View {
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
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        // Keep scrolling content inside the card from every edge — without this
        // the controls scroll out past the top/bottom and the wide horizontal
        // rows run off the side. Clip to the card shape, then stroke on top so
        // the border itself isn't clipped away.
        .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        // Cross-fade the control as the live selection changes while the user
        // scrolls the list, so the pane updates smoothly rather than snapping.
        .animation(.easeInOut(duration: 0.18), value: selectedRowID)
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
    @Environment(\.settingsRowFocusForeground) private var focusFg
    @Environment(\.themePalette) private var palette

    /// Accent selection only shows when this row is the live selection AND the
    /// list does not currently hold focus (focus is in the detail pane).
    private var showSelection: Bool { isSelected && !isFocused }

    private var chevronColor: AnyShapeStyle {
        if isFocused { return AnyShapeStyle(focusFg.opacity(0.65)) }
        if isSelected { return AnyShapeStyle(palette.accent) }
        return AnyShapeStyle(.secondary)
    }

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
            if let value = row.valueSummary {
                Text(value)
                    .font(.subheadline)
                    .settingsRowSecondary()
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(chevronColor)
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
