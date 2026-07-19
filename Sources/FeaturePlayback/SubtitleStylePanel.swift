#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreUI
import CoreModels

/// The live subtitle-appearance editor, extracted from `PlayerControls`. Hosts
/// the Style screen and its detail sub-screens (Font / Shadow & Outline /
/// Background / Dual Subtitles) over the running video so every tweak previews
/// instantly on the real subtitles behind the panel.
///
/// It owns only the appearance-editing content and its hold-to-accelerate ramp
/// (`styleAccelerator`); the panel morph + focus-restore choreography stays in
/// `PlayerControls` and is reached through the injected `openScreen` closure
/// (which forwards to the parent's `openSubtitleScreen`, preserving the deferred
/// focus write). Edits funnel through `updateStyle` -> `actions.setSubtitleStyle`
/// exactly as before, so live preview + profile persistence are unchanged.
struct SubtitleStylePanel: View {
    /// Which style sub-screen to render (style / styleFont / styleOutline /
    /// styleBackground / styleDual). Non-style screens are never routed here.
    let screen: PlayerControls.SubtitleScreen
    let model: PlayerControlsModel
    let palette: ThemePalette
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    /// Forwards to `PlayerControls.openSubtitleScreen`, which animates the panel
    /// morph and defers the focus write. Kept in the parent so the fragile
    /// focus-restore choreography is unchanged by this extraction.
    let openScreen: (PlayerControls.SubtitleScreen) -> Void

    /// Hold-to-accelerate state for the numeric style rows (see the field in the
    /// former PlayerControls home). Lives here because only `handleStyleMove`
    /// touches it.
    @State private var styleAccelerator = SubtitleStyleAccelerator()

    @ViewBuilder
    var body: some View {
        switch screen {
        case .style:
            // A bitmap primary (PGS/DVD/…) is pre-rendered by the source, so NONE
            // of the appearance controls apply. Replace the whole editor with a
            // centered explanation rather than showing dead knobs.
            if let format = model.secondarySubtitleImagePrimaryFormat {
                styleUnavailableForImageSubtitle(format: format)
            } else {
                let main = styleMainRows
                styleScreen(main.rows, dividerBefore: main.dividerBefore)
            }
        case .styleFont: styleFontScreen
        case .styleOutline: styleScreen(styleOutlineRows)
        case .styleBackground: styleScreen(styleBackgroundRows)
        case .styleDual: styleScreen(styleDualRows)
        default: EmptyView()
        }
    }


    struct StyleRowSpec: Identifiable {
        enum Kind {
            /// Numeric range: ←/→ step (hold to accelerate), Select nudges up one.
            /// `step` moves by a signed number of grid indices, clamped at the ends.
            case number(value: String, step: (Int) -> Void)
            /// Small enum: Select cycles next (wrap); ←/→ cycle; no ± glyphs.
            case choice(value: String, prev: () -> Void, next: () -> Void)
            /// On/off: Select flips.
            case toggle(isOn: Bool, flip: () -> Void)
            /// Opens a detail sub-screen: Select opens; shows a `›` chevron.
            case submenu(summary: String, open: () -> Void)
            /// One-shot: Select runs it.
            case action(run: () -> Void)
        }
        let slot: Int
        let title: String
        let kind: Kind
        var id: Int { slot }
    }

    /// The live subtitle-appearance editor, hosted over the running video so every
    /// tweak previews instantly on the real subtitles behind the panel. Each row is
    /// a single full-width Button (one focus target spanning the width, so vertical
    /// focus lands predictably), value right-aligned. Steppers reveal −/+ glyphs
    /// only while focused (press ←/→ on the remote to adjust); the container's
    /// `.onMoveCommand` — attached to the non-focusable VStack so children keep
    /// native up/down nav — dispatches those left/right steps to the focused row.
    /// Edits funnel through `updateStyle` → `actions.setSubtitleStyle` (live overlay
    /// + profile persistence). Back lives in the panel header.
    @ViewBuilder
    private func styleScreen(_ rows: [StyleRowSpec], dividerBefore: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                if let d = dividerBefore, row.slot == d {
                    Divider()
                        .background(.white.opacity(0.12))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                styleRow(row)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .top)
        .plozzMoveCommand { direction in
            handleStyleMove(direction, rows: rows)
        }
    }

    /// One rendered row, laid out to match the track/audio rows exactly: a full-width
    /// Button with the title hard-left and the value/glyph hard-right, so titles and
    /// values carry equal edge gutters. Steppers reveal −/+ flanking the value on
    /// focus; submenus show a trailing chevron.
    @ViewBuilder
    private func styleRow(_ row: StyleRowSpec) -> some View {
        let isFocused = focus == .row(row.slot)
        Button {
            switch row.kind {
            case let .number(_, step): step(1)
            case let .choice(_, _, next): next()
            case let .toggle(_, flip): flip()
            case let .submenu(_, open): open()
            case let .action(run): run()
            }
        } label: {
            // Mirror the track/audio rows exactly: title hard-left, a Spacer, and
            // the value/glyph hard-right against the same trailing padding the
            // checkmark uses. Title and trailing element therefore carry equal edge
            // gutters (no extra leading slot pushing the title in).
            HStack(spacing: 10) {
                Text(row.title).font(.body).lineLimit(1)
                Spacer(minLength: 8)
                styleRowTrailing(row, isFocused: isFocused)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(row.slot))
    }

    @ViewBuilder
    private func styleRowTrailing(_ row: StyleRowSpec, isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            // − appears on focus for steppers, immediately left of the value.
            if case .number = row.kind, isFocused {
                Image(systemName: "minus").font(.body.weight(.semibold))
            }

            styleRowValue(row)

            // + on focus for steppers, or a persistent chevron for submenus — both
            // sit at the trailing edge, exactly where the track rows put their
            // checkmark, so the value column hugs the right like every other menu.
            switch row.kind {
            case .number:
                if isFocused { Image(systemName: "plus").font(.body.weight(.semibold)) }
            case .submenu:
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .playerMenuRowSecondary()
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func styleRowValue(_ row: StyleRowSpec) -> some View {
        switch row.kind {
        case let .number(value, _):
            Text(value).font(.body).monospacedDigit().playerMenuRowSecondary()
        case let .choice(value, _, _):
            Text(value).font(.body).lineLimit(2).multilineTextAlignment(.trailing).playerMenuRowSecondary()
        case let .toggle(isOn, _):
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .playerMenuRowMark(isSelected: isOn, accent: palette.accent)
        case let .submenu(summary, _):
            Text(summary).font(.body).playerMenuRowSecondary()
        case .action:
            EmptyView()
        }
    }

    /// Container-level ←/→ handler: looks up the focused slot's row and steps it.
    /// Up/down are left to the native focus engine (single column → left/right
    /// find no sibling, so focus stays put and this handler fires instead).
    private func handleStyleMove(_ direction: PlozzMoveCommandDirection, rows: [StyleRowSpec]) {
        guard case let .row(slot)? = focus,
              let row = rows.first(where: { $0.slot == slot }) else { return }
        switch (direction, row.kind) {
        case let (.left, .number(_, step)):
            step(-styleAccelerator.magnitude(slot: slot, sign: -1))
        case let (.right, .number(_, step)):
            step(styleAccelerator.magnitude(slot: slot, sign: 1))
        case let (.left, .choice(_, prev, _)):
            prev()
        case let (.right, .choice(_, _, next)):
            next()
        default:
            break
        }
    }

    // MARK: Per-screen row builders

    /// Main flat Style screen: the common per-glyph knobs, a divider, then the
    /// submenu groups (outline/border, background box, dual subtitles) and Reset.
    /// The submenus own the quick control as their first row *and* echo its current
    /// value as their summary, so there is exactly one entry per concern here.
    private var styleMainRows: (rows: [StyleRowSpec], dividerBefore: Int) {
        let s = model.subtitleStyle
        let weights = s.fontFamily.availableWeights
        var rows: [StyleRowSpec] = []
        var slot = 0

        rows.append(StyleRowSpec(slot: slot, title: "Font", kind: .submenu(summary: s.fontFamily.displayName, open: { openScreen(.styleFont) }))); slot += 1
        rows.append(choiceRow(slot, "Weight", options: weights, current: s.fontWeight.snapped(to: weights), label: { $0.displayName }) { v in updateStyle { $0.fontWeight = v } }); slot += 1
        rows.append(numberRow(slot, "Text Size", options: Self.sizeOptions, current: Int((s.fontScale * 100).rounded()), label: { "\($0)%" }) { v in updateStyle { $0.fontScale = Double(v) / 100 } }); slot += 1
        rows.append(numberRow(slot, "Position", options: Self.positionOptions, current: Int((s.verticalPosition * 100).rounded()), label: PlayerControlsFormatting.positionLabel) { v in updateStyle { $0.verticalPosition = Double(v) / 100 } }); slot += 1
        rows.append(numberRow(slot, "Horizontal Offset", options: Self.hOffsetOptions, current: Int((s.horizontalOffset * 100).rounded()), label: PlayerControlsFormatting.hOffsetLabel) { v in updateStyle { $0.horizontalOffset = Double(v) / 100 } }); slot += 1
        rows.append(colorRow(slot, "Text Color", options: Self.textColorOptions, current: s.textColor, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.textColor = c } }); slot += 1
        rows.append(numberRow(slot, "Opacity", options: Self.opacityOptions, current: Int((s.opacity * 100).rounded()), label: { "\($0)%" }) { v in updateStyle { $0.opacity = Double(v) / 100 } }); slot += 1
        // Only affects HDR frames, so it appears exclusively while HDR is live —
        // mirroring how the bitmap-primary gate hides controls that can't act.
        if model.subtitlesRenderHDR {
            rows.append(numberRow(slot, "HDR Brightness", options: Self.hdrBrightnessOptions, current: Int((s.hdrLuminanceScale * 100).rounded()), label: { "\($0)%" }) { v in updateStyle { $0.hdrLuminanceScale = Double(v) / 100 } }); slot += 1
        }

        // The submenu group + Reset sit under a divider, wherever the knobs above end.
        let dividerBefore = slot
        rows.append(StyleRowSpec(slot: slot, title: "Shadow & Outline", kind: .submenu(summary: PlayerControlsFormatting.edgeSummary(s), open: { openScreen(.styleOutline) }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Background", kind: .submenu(summary: s.background.isEnabled ? "On" : "Off", open: { openScreen(.styleBackground) }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Dual Subtitles", kind: .submenu(summary: hasSecondaryTrack ? "On" : "Off", open: { openScreen(.styleDual) }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Reset to Default", kind: .action(run: { updateStyle { $0 = .default } }))); slot += 1
        return (rows, dividerBefore)
    }

    /// The Font picker: one selectable row per family, each rendered **in its own
    /// typeface** (a touch larger than the value rows) so the list previews itself.
    /// Selecting a font applies it and returns to the Style screen; the chosen
    /// weight persists and is re-snapped to the new family's available weights by
    /// the renderer and the Weight row.
    @ViewBuilder
    private var styleFontScreen: some View {
        let current = model.subtitleStyle.fontFamily
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SubtitleFontFamily.allCases.enumerated()), id: \.offset) { idx, family in
                fontChoiceRow(family, index: idx, isSelected: family == current)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func fontChoiceRow(_ family: SubtitleFontFamily, index: Int, isSelected: Bool) -> some View {
        Button {
            updateStyle { $0.fontFamily = family }
            openScreen(.style)
        } label: {
            HStack(spacing: 10) {
                Text(family.displayName)
                    .font(Self.fontPreviewFont(for: family))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .playerMenuRowMark(isSelected: isSelected, accent: palette.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(index))
    }

    /// A SwiftUI `Font` that renders a family's name in that family's own Regular
    /// face — bundled faces via their PostScript name, SF via the system font, and
    /// SF Rounded via the rounded system design.
    private static func fontPreviewFont(for family: SubtitleFontFamily) -> Font {
        // OpenDyslexic's wide, heavy letterforms already read large, so it gets a
        // smaller preview; every other family is bumped up for a bolder, more
        // legible list.
        let size: CGFloat = family == .openDyslexic ? 30 : 40
        if family.usesRoundedDesign { return .system(size: size, design: .rounded) }
        if let stem = family.postScriptStem { return .custom("\(stem)-Regular", size: size) }
        return .system(size: size)
    }

    /// Shadow (depth) + a single glyph Outline — two independent concerns that
    /// compose freely (e.g. a drop shadow *and* an outline at once). Rows for each
    /// group's colour/size reveal only when that group is active, so there are no
    /// dead controls and never two competing "outline" concepts.
    private var styleOutlineRows: [StyleRowSpec] {
        let s = model.subtitleStyle
        var rows: [StyleRowSpec] = []
        var slot = 0

        rows.append(choiceRow(slot, "Shadow", options: Self.shadowStyleOptions, current: s.edge.style, label: { $0.displayName }) { v in updateStyle { $0.edge.style = v } }); slot += 1
        if s.edge.style != .none {
            rows.append(colorRow(slot, "Shadow Color", options: Self.textColorOptions, current: s.edge.color, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.edge.color = c } }); slot += 1
            rows.append(numberRow(slot, "Shadow Thickness", options: Self.thicknessOptions, current: Int(s.edge.thickness.rounded()), label: { "\($0)" }) { v in updateStyle { $0.edge.thickness = Double(v) } }); slot += 1
        }

        rows.append(StyleRowSpec(slot: slot, title: "Outline", kind: .toggle(isOn: s.border.isEnabled, flip: { updateStyle { $0.border.isEnabled.toggle() } }))); slot += 1
        if s.border.isEnabled {
            rows.append(colorRow(slot, "Outline Color", options: Self.textColorOptions, current: s.border.color, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.border.color = c } }); slot += 1
            rows.append(numberRow(slot, "Outline Width", options: Self.thicknessOptions, current: Int(s.border.width.rounded()), label: { "\($0)" }) { v in updateStyle { $0.border.width = Double(v) } }); slot += 1
        }
        return rows
    }

    /// Background box: colour, its own opacity, corner radius and padding.
    private var styleBackgroundRows: [StyleRowSpec] {
        let s = model.subtitleStyle
        var rows: [StyleRowSpec] = [
            StyleRowSpec(slot: 0, title: "Show Box", kind: .toggle(isOn: s.background.isEnabled, flip: { updateStyle { $0.background.isEnabled.toggle() } })),
        ]
        // The box's colour/opacity/shape only matter when it's shown; hide them
        // while it's off so focus never lands on a control with no visible effect
        // (matching the Outline and Dual screens' gating).
        guard s.background.isEnabled else { return rows }
        var slot = 1
        rows.append(colorRow(slot, "Color", options: Self.boxColorOptions, current: s.background.color, label: PlayerControlsFormatting.boxColorLabel) { c in updateStyle { $0.background.color = c } }); slot += 1
        rows.append(numberRow(slot, "Box Opacity", options: Self.boxOpacityOptions, current: Int((s.background.color.alpha * 100).rounded()), label: { "\($0)%" }) { v in updateStyle { $0.background.color.alpha = Double(v) / 100 } }); slot += 1
        rows.append(numberRow(slot, "Corner Radius", options: Self.cornerOptions, current: Int(s.background.cornerRadius.rounded()), label: PlayerControlsFormatting.cornerLabel) { v in updateStyle { $0.background.cornerRadius = Double(v) } }); slot += 1
        rows.append(numberRow(slot, "Horizontal Padding", options: Self.paddingOptions, current: Int(s.background.horizontalPadding.rounded()), label: { "\($0)" }) { v in updateStyle { $0.background.horizontalPadding = Double(v) } }); slot += 1
        rows.append(numberRow(slot, "Vertical Padding", options: Self.paddingOptions, current: Int(s.background.verticalPadding.rounded()), label: { "\($0)" }) { v in updateStyle { $0.background.verticalPadding = Double(v) } }); slot += 1
        return rows
    }

    /// True when a real (non-"Off") second subtitle track is currently selected,
    /// so the main Style screen can label "Dual Subtitles" On/Off correctly.
    private var hasSecondaryTrack: Bool {
        guard let sel = model.secondarySubtitleOptions.first(where: { $0.isSelected }) else { return false }
        return sel.id != PlayerTrackOption.offID
    }

    /// Dual subtitles: pick a second track to show a second line, then (optionally)
    /// distinguish its look. The picker lists text tracks the overlay can draw
    /// (excluding the primary); its styling rows appear only once a track is on.
    private var styleDualRows: [StyleRowSpec] {
        let s = model.subtitleStyle
        let secOptions = model.secondarySubtitleOptions
        let count = secOptions.count
        let currentIdx = secOptions.firstIndex(where: { $0.isSelected }) ?? 0
        let step: (Int) -> Void = { delta in
            guard count > 0 else { return }
            let next = secOptions[((currentIdx + delta) % count + count) % count]
            actions.selectSecondarySubtitle(next.id)
        }
        let selected = secOptions.first(where: { $0.isSelected })
        let hasTrack = selected != nil && selected?.id != PlayerTrackOption.offID
        // Base value = the selected option's label; when a real track is selected,
        // annotate it with the live load status so the viewer can see whether it's
        // fetching, has no lines in this file, or the sidecar was unavailable —
        // instead of a silent blank second line. When the primary is a bitmap sub,
        // dual mode is disallowed (a PGS/DVD line can't be positioned), so say so
        // explicitly rather than the ambiguous "None available".
        let baseValue: String
        if let format = model.secondarySubtitleImagePrimaryFormat {
            baseValue = "Disabled for \(format)"
        } else if secOptions.isEmpty {
            baseValue = "None available"
        } else {
            baseValue = secOptions[currentIdx].title
        }
        let trackValue = hasTrack ? baseValue + Self.secondaryStatusSuffix(model.secondarySubtitleStatus) : baseValue
        var rows: [StyleRowSpec] = [
            StyleRowSpec(slot: 0, title: "Second Track", kind: .choice(
                value: trackValue,
                prev: { step(-1) },
                next: { step(1) }
            )),
        ]
        if hasTrack, let sec = s.secondary {
            var slot = 1
            rows.append(choiceRow(slot, "Placement", options: SubtitleStyle.Secondary.Placement.allCases, current: sec.placement, label: { $0 == .above ? "Above" : "Below" }) { v in updateStyle { $0.secondary?.placement = v } }); slot += 1
            rows.append(StyleRowSpec(slot: slot, title: "Distinct Style", kind: .toggle(isOn: sec.differentiate, flip: { updateStyle { $0.secondary?.differentiate.toggle() } }))); slot += 1
            // Size + Colour only take effect when the secondary uses a distinct
            // style — otherwise the renderer mirrors the primary's size/colour
            // (see SubtitleOverlayView). Hide them while Distinct Style is off so
            // they're not dead controls.
            if sec.differentiate {
                rows.append(numberRow(slot, "Size", options: Self.secondarySizeOptions, current: Int((sec.relativeScale * 100).rounded()), label: { "\($0)%" }) { v in updateStyle { $0.secondary?.relativeScale = Double(v) / 100 } }); slot += 1
                rows.append(colorRow(slot, "Color", options: Self.textColorOptions, current: sec.textColor, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.secondary?.textColor = c } }); slot += 1
            }
            rows.append(numberRow(slot, "Gap", options: Self.gapOptions, current: Int(sec.gap.rounded()), label: { "\($0)" }) { v in updateStyle { $0.secondary?.gap = Double(v) } }); slot += 1
        }
        return rows
    }

    /// A short suffix annotating the selected second track with its load state.
    /// Always shows the outcome (loading / cue count / no lines / unavailable) so a
    /// track that fetched cues but still won't draw is distinguishable on-screen
    /// from one that genuinely returned nothing.
    private static func secondaryStatusSuffix(_ status: SecondarySubtitleStatus) -> String {
        switch status {
        case .idle: return ""
        case .loading: return "  ·  loading…"
        case .loaded(let n): return n > 0 ? "  ·  \(n) cues" : "  ·  no lines"
        case .unavailable: return "  ·  unavailable"
        }
    }

    // MARK: Row constructors

    /// Numeric stepper row over an Int grid; snaps a legacy off-grid value to the
    /// nearest listed option so it still displays and steps cleanly. Steps by a
    /// signed number of grid indices and clamps at both ends (no wrap), so a fast
    /// hold-to-accelerate run parks at Bottom/Top instead of jumping across.
    private func numberRow(_ slot: Int, _ title: String, options: [Int], current: Int, label: @escaping (Int) -> String, apply: @escaping (Int) -> Void) -> StyleRowSpec {
        let n = options.count
        let idx = Self.nearestIndex(options, current)
        return StyleRowSpec(slot: slot, title: title, kind: .number(
            value: label(options[idx]),
            step: { delta in
                let target = min(max(idx + delta, 0), n - 1)
                if target != idx { apply(options[target]) }
            }
        ))
    }

    /// Cycle row over any small `Equatable` set; wraps at both ends.
    private func choiceRow<V: Equatable>(_ slot: Int, _ title: String, options: [V], current: V, label: @escaping (V) -> String, apply: @escaping (V) -> Void) -> StyleRowSpec {
        let n = options.count
        let idx = options.firstIndex(of: current) ?? 0
        return StyleRowSpec(slot: slot, title: title, kind: .choice(
            value: label(options[idx]),
            prev: { apply(options[(idx - 1 + n) % n]) },
            next: { apply(options[(idx + 1) % n]) }
        ))
    }

    /// Cycle row over a colour palette, matched by RGB so it recognises the current
    /// swatch regardless of its alpha, and preserves that alpha on change (so the
    /// separate opacity knobs stay independent of the colour choice).
    private func colorRow(_ slot: Int, _ title: String, options: [SubtitleColor], current: SubtitleColor, label: @escaping (SubtitleColor) -> String, apply: @escaping (SubtitleColor) -> Void) -> StyleRowSpec {
        let n = options.count
        let idx = options.firstIndex(where: { $0.red == current.red && $0.green == current.green && $0.blue == current.blue }) ?? 0
        func withAlpha(_ c: SubtitleColor) -> SubtitleColor { SubtitleColor(red: c.red, green: c.green, blue: c.blue, alpha: current.alpha) }
        return StyleRowSpec(slot: slot, title: title, kind: .choice(
            value: label(current),
            prev: { apply(withAlpha(options[(idx - 1 + n) % n])) },
            next: { apply(withAlpha(options[(idx + 1) % n])) }
        ))
    }

    /// Reads the mirror, applies the mutation, and routes the result through the
    /// live-apply + persist funnel. Single write path for every appearance control.
    private func updateStyle(_ mutate: (inout SubtitleStyle) -> Void) {
        var next = model.subtitleStyle
        mutate(&next)
        actions.setSubtitleStyle(next)
    }

    // MARK: Option grids

    // Precise, numeric option grids — no "low / high" buckets.
    private static let sizeOptions: [Int] = Array(stride(from: 60, through: 250, by: 5))
    private static let positionOptions: [Int] = Array(stride(from: 0, through: 90, by: 1))
    /// Horizontal nudge as a signed percentage of the max offset (±25% of width);
    /// 0 = centred. Lets subtitles dodge burned-in signage / letterbox furniture.
    private static let hOffsetOptions: [Int] = Array(stride(from: -100, through: 100, by: 5))
    private static let opacityOptions: [Int] = Array(stride(from: 20, through: 100, by: 5))
    /// The box's own opacity floors lower than text opacity (down to 5%) so a
    /// near-invisible scrim is possible without dragging the text there too.
    private static let boxOpacityOptions: [Int] = Array(stride(from: 5, through: 100, by: 5))
    /// Subtitle HDR white-point scale, shown as a percentage. Mirrors the model's
    /// `hdrLuminanceScale` (0.2–1.0); only surfaced while HDR is live.
    private static let hdrBrightnessOptions: [Int] = Array(stride(from: 20, through: 100, by: 5))
    private static let thicknessOptions: [Int] = Array(stride(from: 0, through: 10, by: 1))
    /// Shadow (depth) styles only — the outline is now its own toggle, so the old
    /// `.uniform` case is intentionally not offered here.
    private static let shadowStyleOptions: [SubtitleEdgeStyle] = [.none, .dropShadow, .raised, .depressed]
    /// Corner radius in points, then a large sentinel the box renderer clamps to a
    /// perfect capsule (`UIBezierPath` caps the radius at half the shorter side),
    /// so the top of the range always reads as "fully rounded" at any box size.
    private static let cornerFull = PlayerControlsFormatting.cornerFull
    private static let cornerOptions: [Int] = Array(stride(from: 0, through: 40, by: 2)) + [cornerFull]
    private static let paddingOptions: [Int] = Array(stride(from: 0, through: 40, by: 2))
    private static let gapOptions: [Int] = Array(stride(from: 0, through: 24, by: 2))
    private static let secondarySizeOptions: [Int] = Array(stride(from: 50, through: 100, by: 5))
    private static let textColorOptions: [SubtitleColor] = SubtitleColor.presets.map(\.color)
    // RGB representatives (alpha handled by the Box Opacity knob).
    private static let boxColorOptions: [SubtitleColor] = [
        SubtitleColor(red: 0, green: 0, blue: 0, alpha: 1),
        SubtitleColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1),
        SubtitleColor(red: 1, green: 1, blue: 1, alpha: 1)
    ]

    private static func nearestIndex(_ options: [Int], _ value: Int) -> Int {
        PlayerControlsFormatting.nearestIndex(options, value)
    }

    /// Shown in place of the whole style editor when the primary subtitle is a
    /// bitmap (PGS/DVD/DVB/VobSub): those cues are pre-rendered images by the
    /// source, so none of the font/colour/size/position controls apply. A calm
    /// centered card explains why rather than presenting dead knobs.
    private func styleUnavailableForImageSubtitle(format: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "photo")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
            Text("\(format) subtitles can't be restyled")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("They're rendered as images by the source, so font, colour, size and position controls don't apply.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
#endif
