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

    var body: some View {
        SettingsSplitLayout(title: "Circadian Mode", sections: sections)
            .onChange(of: model.settings.isEnabled) { _, enabled in
                if !enabled { model.isPreviewing = false }
            }
            .onDisappear { model.isPreviewing = false }
    }

    private var sections: [SettingsSplitSection] {
        @Bindable var model = model

        // One control governs on/off *and* schedule (Off · Auto · Manual ·
        // Always On), so the first section is just that plus Fade.
        var primaryRows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "night-shift",
                title: "Circadian Mode",
                description: "Warms and dims the display at night to help you sleep.",
            ) {
                NightShiftScheduleControl(model: model)
            }
        ]

        // Fade governs only the on/off transition, so it is irrelevant when the
        // tint is off or always on.
        if model.settings.isEnabled, model.settings.scheduleMode != .alwaysOn {
            primaryRows.append(
                SettingsSplitRow(
                    id: "fade",
                    title: "Fade",
                    description: "How gradually the tint ramps on and off around the scheduled times.",
                ) {
                    SettingsStepper(
                        options: NightShiftSettingsModel.fadeOptions,
                        selection: Binding(
                            get: { clampedFade },
                            set: { model.settings.fadeMinutes = $0 }
                        ),
                        title: { NightShiftSettingsModel.fadeLabel(minutes: $0) }
                    )
                }
            )
        }

        var sections: [SettingsSplitSection] = [
            SettingsSplitSection(id: "night-shift", header: nil, rows: primaryRows)
        ]

        // Off hides the rest — there's nothing to tune when the tint never paints.
        guard model.settings.isEnabled else { return sections }

        sections.append(
            SettingsSplitSection(id: "look", header: "Look", rows: [
                SettingsSplitRow(
                    id: "darkness",
                    title: "Darkness",
                    description: "Dims the whole picture like sunglasses. Focus a row to preview at full night strength.",
                ) {
                    SettingsOptionList(
                        options: NightShiftDimness.allCases,
                        selection: $model.settings.dimness,
                        onFocusChange: { model.isPreviewing = $0 },
                        title: { $0.displayName }
                    )
                },
                SettingsSplitRow(
                    id: "warmth",
                    title: "Warmth",
                    description: "Tints the picture toward amber and red. Focus a row to preview at full night strength.",
                ) {
                    SettingsOptionList(
                        options: NightShiftWarmth.allCases,
                        selection: $model.settings.warmth,
                        onFocusChange: { model.isPreviewing = $0 },
                        title: { $0.displayName }
                    )
                },
                SettingsSplitRow(
                    id: "preview",
                    title: "Preview",
                    description: "Play a whole simulated day to see how the tint moves from daytime through sunset to night."
                ) {
                    HStack(spacing: 28) {
                        DayNightDial(
                            intensity: model.currentIntensity,
                            progress: model.previewProgress
                        )
                        .frame(width: 160, height: 84)

                        previewButton
                        Spacer(minLength: 0)
                    }
                }
            ])
        )

        return sections
    }

    // MARK: - Appearance

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
    }

    // MARK: - Building blocks

    /// `fadeMinutes` snapped to the nearest available preset, so the Fade row
    /// always highlights a valid option even if a persisted value falls between.
    private var clampedFade: Int {
        NightShiftSettingsModel.fadeOptions.min(by: {
            abs($0 - model.settings.fadeMinutes) < abs($1 - model.settings.fadeMinutes)
        }) ?? 90
    }
}

// MARK: - Unified schedule control

/// The single Night Shift control: one segmented toggle —
/// Off · Auto · Manual · Always On — that folds the old separate "Enable" switch
/// (now the **Off** segment) into the schedule choice. A live description
/// follows focus (like Skip Intros / Subtitles), and the mode-specific extras —
/// a location picker for Auto, the two wrap-around clock steppers for Manual —
/// sit inline beneath it. Off and Always On need no extras. Extras track the
/// *committed* selection, not focus, so browsing the segments never shuffles the
/// layout.
private struct NightShiftScheduleControl: View {
    @Bindable var model: NightShiftSettingsModel

    @State private var focusedMode: NightShiftMode?

    /// Focused option wins (live browsing); otherwise describe what's selected.
    private var describedMode: NightShiftMode { focusedMode ?? mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSegmentedPicker(
                options: NightShiftMode.allCases,
                selection: modeBinding,
                title: { $0.title },
                onFocusedOptionChange: { focusedMode = $0 }
            )

            Text(describedMode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)

            modeExtras
        }
        .animation(.easeInOut(duration: 0.18), value: describedMode)
        .animation(.easeInOut(duration: 0.18), value: mode)
    }

    /// Controls specific to the committed mode: a location picker for Auto, the
    /// two wrap-around clock steppers for Manual. Off and Always On show nothing.
    @ViewBuilder
    private var modeExtras: some View {
        switch mode {
        case .off, .alwaysOn:
            EmptyView()
        case .auto:
            LabeledSettingRow("Location") { locationMenu }
        case .manual:
            VStack(alignment: .leading, spacing: 20) {
                LabeledSettingRow("Turns on") {
                    timeStepper(minutes: model.settings.manualOnMinutes) {
                        model.settings.manualOnMinutes = $0
                    }
                }
                LabeledSettingRow("Turns off") {
                    timeStepper(minutes: model.settings.manualOffMinutes) {
                        model.settings.manualOffMinutes = $0
                    }
                }
            }
        }
    }

    // MARK: Mode binding

    /// The current unified mode, derived from `isEnabled` + `scheduleMode`.
    private var mode: NightShiftMode {
        guard model.settings.isEnabled else { return .off }
        switch model.settings.scheduleMode {
        case .solar: return .auto
        case .manual: return .manual
        case .alwaysOn: return .alwaysOn
        }
    }

    /// Writes the unified mode back onto the two persisted fields. Off flips the
    /// master switch and leaves the last schedule mode intact, so re-enabling
    /// returns to it; the others enable and select their schedule.
    private var modeBinding: Binding<NightShiftMode> {
        Binding(
            get: { mode },
            set: { newMode in
                switch newMode {
                case .off:
                    model.settings.isEnabled = false
                case .auto:
                    model.settings.isEnabled = true
                    model.settings.scheduleMode = .solar
                case .manual:
                    model.settings.isEnabled = true
                    model.settings.scheduleMode = .manual
                case .alwaysOn:
                    model.settings.isEnabled = true
                    model.settings.scheduleMode = .alwaysOn
                }
            }
        )
    }

    // MARK: Extras

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
    }

    /// A ±15-minute clock stepper that wraps around midnight, reusing the shared
    /// ``SettingsStepper`` so the manual on/off times get the same − / value / +
    /// control as Fade and the Skip Intervals. The arrows never disable; they
    /// nudge the manual on/off time by one step per press and wrap past midnight.
    private func timeStepper(
        minutes: Int,
        commit: @escaping (Int) -> Void
    ) -> some View {
        SettingsStepper(
            options: Self.clockOptions,
            selection: Binding(
                get: { Self.nearestClockOption(to: minutes) },
                set: { commit($0) }
            ),
            wraps: true,
            title: { model.clockLabel(minutes: $0) }
        )
    }

    /// Every step across a day (00:00 … 23:45 at the manual step granularity),
    /// the option set the manual on/off steppers cycle through.
    private static let clockOptions: [Int] =
        Array(stride(from: 0, to: 24 * 60, by: NightShiftSettingsModel.manualStepMinutes))

    /// Snaps an arbitrary minutes-since-midnight value onto the nearest clock
    /// option so a persisted off-grid time still highlights a valid step. Uses
    /// circular distance so a time just before midnight (e.g. 23:59) snaps to
    /// 00:00 rather than the linearly-closer 23:45.
    private static func nearestClockOption(to minutes: Int) -> Int {
        let wrapped = ((minutes % 1440) + 1440) % 1440
        func circularDistance(_ option: Int) -> Int {
            let raw = abs(option - wrapped)
            return min(raw, 1440 - raw)
        }
        return clockOptions.min(by: {
            circularDistance($0) < circularDistance($1)
        }) ?? wrapped
    }
}

// MARK: - Unified mode

/// The four states of the unified Night Shift control. **Off** replaces the old
/// standalone enable switch; the other three mirror `NightShiftScheduleMode`.
private enum NightShiftMode: String, CaseIterable, Hashable {
    case off, auto, manual, alwaysOn

    var title: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto"
        case .manual: return "Manual"
        case .alwaysOn: return "Always On"
        }
    }

    /// One-line, plain-language behaviour shown live under the toggle. Auto and
    /// Manual stay generic because the concrete schedule (location / times) sits
    /// right below in the mode's own controls.
    var detail: String {
        switch self {
        case .off: return "The picture is never dimmed or warmed."
        case .auto: return "Warms automatically from sunset to sunrise for your location."
        case .manual: return "Warms between two times you set each day."
        case .alwaysOn: return "Always warm, at full strength, around the clock."
        }
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
