#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Night Shift: a warm, f.lux-style screen tint that fades in after sunset (or on
/// a manual schedule) and out before sunrise. tvOS can't warm the system display,
/// so this multiplies the app's own content (player included) via the window
/// overlay installed at the app root. Per-profile — each household profile keeps
/// its own schedule and intensity.
struct NightShiftDetailView: View {
    @Bindable var model: NightShiftSettingsModel

    /// Which control row currently holds focus. Focusing the Darkness or Warmth
    /// row flips the overlay to full strength so each level is visible live at
    /// deep-night intensity; other rows leave the live schedule untouched.
    private enum Field: Hashable {
        case schedule, location, onTime, offTime, fade, darkness, warmth, preview
    }
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Night Shift").font(.largeTitle.bold())

                SettingsPanel(footer: model.scheduleSummary()) {
                    Toggle("Enable Night Shift", isOn: $model.settings.isEnabled)
                        .font(.callout.weight(.medium))
                }

                if model.settings.isEnabled {
                    schedulePanel
                    appearancePanel
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .onChange(of: focusedField) { _, field in
            // Full-strength calibration preview only while the Darkness/Warmth row
            // is focused, so the viewer can judge the deep-night look; it switches
            // off the moment focus moves elsewhere.
            model.isPreviewing = (field == .darkness || field == .warmth)
        }
        .onChange(of: model.settings.isEnabled) { _, enabled in
            if !enabled { model.isPreviewing = false }
        }
        .onDisappear { model.isPreviewing = false }
    }

    // MARK: - Schedule

    private var schedulePanel: some View {
        SettingsPanel(
            title: "Schedule",
            footer: "Auto follows your chosen city's sunset and sunrise. Manual turns Night Shift on and off at two fixed times in this Apple TV's time zone."
        ) {
            VStack(alignment: .leading, spacing: 24) {
                labeledRow("When") {
                    optionRow(
                        NightShiftScheduleMode.allCases,
                        selected: model.settings.scheduleMode,
                        label: { $0.displayName },
                        focus: .schedule
                    ) { model.settings.scheduleMode = $0 }
                }

                if model.settings.scheduleMode == .solar {
                    labeledRow("Location") { locationMenu }
                } else {
                    HStack(alignment: .top, spacing: 40) {
                        labeledRow("Turns on") {
                            timeStepper(
                                minutes: model.settings.manualOnMinutes,
                                focus: .onTime
                            ) { model.settings.manualOnMinutes = $0 }
                        }
                        labeledRow("Turns off") {
                            timeStepper(
                                minutes: model.settings.manualOffMinutes,
                                focus: .offTime
                            ) { model.settings.manualOffMinutes = $0 }
                        }
                    }
                }

                labeledRow("Fade") {
                    optionRow(
                        NightShiftSettingsModel.fadeOptions,
                        selected: clampedFade,
                        label: { NightShiftSettingsModel.fadeLabel(minutes: $0) },
                        focus: .fade
                    ) { model.settings.fadeMinutes = $0 }
                }
            }
        }
    }

    private var locationMenu: some View {
        Menu {
            Picker("Location", selection: $model.settings.regionID) {
                ForEach(NightShiftRegion.sortedCatalog) { region in
                    Text(region.name).tag(region.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                Text(model.region.name)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
            }
            .font(.headline)
            .padding(.horizontal, 4)
        }
        .buttonStyle(PlozzSeasonTabStyle(isSelected: false))
        .focused($focusedField, equals: .location)
    }

    // MARK: - Appearance

    private var appearancePanel: some View {
        SettingsPanel(
            title: "Look",
            footer: "Darkness dims the whole picture like sunglasses; Warmth tints it toward amber and red. Focus Darkness or Warmth to preview at full night strength, or play a whole day below."
        ) {
            VStack(alignment: .leading, spacing: 24) {
                labeledRow("Darkness") {
                    optionRow(
                        NightShiftDimness.allCases,
                        selected: model.settings.dimness,
                        label: { $0.displayName },
                        focus: .darkness
                    ) { model.settings.dimness = $0 }
                }
                labeledRow("Warmth") {
                    optionRow(
                        NightShiftWarmth.allCases,
                        selected: model.settings.warmth,
                        label: { $0.displayName },
                        focus: .warmth
                    ) { model.settings.warmth = $0 }
                }

                HStack(spacing: 28) {
                    DayNightDial(
                        intensity: model.currentIntensity,
                        progress: model.previewProgress
                    )
                    .frame(width: 160, height: 84)

                    previewButton
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
        }
    }

    private var previewButton: some View {
        Button {
            model.runDayNightPreview()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "moon.stars.fill")
                Text(model.previewProgress == nil ? "Preview a day" : model.previewClockText)
                    .monospacedDigit()
            }
            .font(.headline)
            .padding(.horizontal, 4)
        }
        .buttonStyle(PlozzSeasonTabStyle(isSelected: false))
        .focused($focusedField, equals: .preview)
    }

    // MARK: - Building blocks

    /// `fadeMinutes` snapped to the nearest available preset, so the Fade row
    /// always highlights a valid option even if a persisted value falls between.
    private var clampedFade: Int {
        NightShiftSettingsModel.fadeOptions.min(by: {
            abs($0 - model.settings.fadeMinutes) < abs($1 - model.settings.fadeMinutes)
        }) ?? 90
    }

    private func labeledRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// A horizontal row of selectable pills over a discrete list of options,
    /// matching the Appearance picker idiom. When `focus` is set, every pill in
    /// the row shares that focus value so the row reads as "focused" for the live
    /// calibration preview regardless of which pill the cursor lands on.
    private func optionRow<Option: Hashable>(
        _ options: [Option],
        selected: Option,
        label: @escaping (Option) -> String,
        focus: Field? = nil,
        select: @escaping (Option) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(options, id: \.self) { option in
                    Button {
                        select(option)
                    } label: {
                        HStack(spacing: 10) {
                            Text(label(option))
                            if option == selected {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        .font(.headline)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(PlozzSeasonTabStyle(isSelected: option == selected))
                    .focused($focusedField, equals: focus)
                    .accessibilityValue(option == selected ? "Selected" : "")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .scrollClipDisabled()
    }

    /// A ±15-minute clock stepper that wraps around midnight. The arrows never
    /// disable; they nudge the manual on/off time by one step per press.
    private func timeStepper(
        minutes: Int,
        focus: Field,
        commit: @escaping (Int) -> Void
    ) -> some View {
        let step = NightShiftSettingsModel.manualStepMinutes
        return HStack(spacing: 16) {
            Button {
                commit(wrappedMinutes(minutes - step))
            } label: {
                Image(systemName: "minus").font(.headline)
            }
            .plozzGlassPillButton(shape: .circle)
            .focused($focusedField, equals: focus)

            Text(model.clockLabel(minutes: minutes))
                .font(.headline.monospacedDigit())
                .frame(minWidth: 110)

            Button {
                commit(wrappedMinutes(minutes + step))
            } label: {
                Image(systemName: "plus").font(.headline)
            }
            .plozzGlassPillButton(shape: .circle)
        }
    }

    private func wrappedMinutes(_ raw: Int) -> Int {
        ((raw % 1440) + 1440) % 1440
    }
}

// MARK: - Day/night preview dial

/// A tiny self-contained sky: a sun arcs across by day and a moon by night, with
/// the sky colour shifting day → sunset → night to mirror the actual Night Shift
/// intensity. `progress` (0…1) places the celestial body horizontally across the
/// simulated day; when nil (idle) it rests mid-arc.
private struct DayNightDial: View {
    /// 0 = full daylight, 1 = deep night. Drives sky colour + sun vs. moon.
    var intensity: Double
    /// 0…1 sweep position; nil when no preview is running.
    var progress: Double?

    private static let dayTop = (0.40, 0.68, 0.95)
    private static let dayBottom = (0.72, 0.86, 0.99)
    private static let duskTop = (0.86, 0.46, 0.30)
    private static let duskBottom = (0.99, 0.72, 0.38)
    private static let nightTop = (0.03, 0.05, 0.14)
    private static let nightBottom = (0.10, 0.13, 0.26)

    var body: some View {
        let p = progress ?? 0.5
        let sky = skyColors()
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let bodySize = h * 0.34
            let starSize = max(2.0, h * 0.045)
            let x = w * p
            let y = h * (0.84 - 0.58 * sin(.pi * p))
            let isNight = intensity > 0.5
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(colors: [sky.top, sky.bottom], startPoint: .top, endPoint: .bottom)
                    )

                if intensity > 0.55 {
                    ForEach(Array(Self.stars.enumerated()), id: \.offset) { _, star in
                        Circle()
                            .fill(.white.opacity(0.75))
                            .frame(width: starSize, height: starSize)
                            .position(x: w * star.0, y: h * star.1)
                    }
                }

                Circle()
                    .fill(isNight ? Color(.sRGB, red: 0.92, green: 0.94, blue: 1.0)
                                  : Color(.sRGB, red: 1.0, green: 0.86, blue: 0.34))
                    .frame(width: bodySize, height: bodySize)
                    .shadow(
                        color: (isNight ? Color.white : Color(.sRGB, red: 1.0, green: 0.8, blue: 0.3)).opacity(0.6),
                        radius: 6
                    )
                    .position(x: x, y: y)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .animation(.linear(duration: 0.06), value: progress)
    }

    private static let stars: [(Double, Double)] = [(0.24, 0.30), (0.55, 0.48), (0.79, 0.26)]

    private func skyColors() -> (top: Color, bottom: Color) {
        let i = max(0, min(1, intensity))
        let top: (Double, Double, Double)
        let bottom: (Double, Double, Double)
        if i <= 0.5 {
            let t = i / 0.5
            top = lerp(Self.dayTop, Self.duskTop, t)
            bottom = lerp(Self.dayBottom, Self.duskBottom, t)
        } else {
            let t = (i - 0.5) / 0.5
            top = lerp(Self.duskTop, Self.nightTop, t)
            bottom = lerp(Self.duskBottom, Self.nightBottom, t)
        }
        return (color(top), color(bottom))
    }

    private func color(_ rgb: (Double, Double, Double)) -> Color {
        Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    private func lerp(
        _ a: (Double, Double, Double),
        _ b: (Double, Double, Double),
        _ t: Double
    ) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
}
#endif
