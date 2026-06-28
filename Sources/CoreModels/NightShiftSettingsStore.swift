import Foundation
import Observation

// MARK: - Persisted settings

/// All persisted Night Shift selections for one profile, stored as a single JSON
/// blob under a per-profile-namespaced key (mirrors how the other settings stores
/// scope by `Profile.id`). Transient runtime state (the live clock tick, the
/// calibration/day previews) is **not** part of this — it lives on the model.
public struct NightShiftSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// IANA id of the chosen `NightShiftRegion` (solar schedule only).
    public var regionID: String
    public var warmth: NightShiftWarmth
    public var dimness: NightShiftDimness
    public var scheduleMode: NightShiftScheduleMode
    /// Manual "turns on" / "turns off" clock times, minutes since local midnight
    /// (0…1439). Only consulted when `scheduleMode == .manual`.
    public var manualOnMinutes: Int
    public var manualOffMinutes: Int
    /// How many minutes the wash takes to ramp from off to full (and back).
    public var fadeMinutes: Int

    public init(
        isEnabled: Bool,
        regionID: String,
        warmth: NightShiftWarmth,
        dimness: NightShiftDimness,
        scheduleMode: NightShiftScheduleMode,
        manualOnMinutes: Int,
        manualOffMinutes: Int,
        fadeMinutes: Int
    ) {
        self.isEnabled = isEnabled
        self.regionID = regionID
        self.warmth = warmth
        self.dimness = dimness
        self.scheduleMode = scheduleMode
        self.manualOnMinutes = manualOnMinutes
        self.manualOffMinutes = manualOffMinutes
        self.fadeMinutes = fadeMinutes
    }

    /// Off by default; sensible warm/dim levels and a sunset-driven schedule for
    /// the device's best-guess region so turning it On just works.
    public static var `default`: NightShiftSettings {
        NightShiftSettings(
            isEnabled: false,
            regionID: NightShiftRegion.guessFromCurrentTimeZone().id,
            warmth: .warmer,
            dimness: .medium,
            scheduleMode: .solar,
            manualOnMinutes: 20 * 60,
            manualOffMinutes: 6 * 60,
            fadeMinutes: 90
        )
    }
}

// MARK: - Store

/// Persists `NightShiftSettings` across launches in standard `UserDefaults`.
///
/// Mirrors `ThemeSettingsStore` / `SpoilerSettingsStore`: a per-profile namespace
/// scopes the key so each household profile keeps its own Night Shift state. The
/// default/primary profile passes `namespace: nil` (un-suffixed key).
public protocol NightShiftSettingsStoring: Sendable {
    func load() -> NightShiftSettings
    func save(_ settings: NightShiftSettings)
}

public final class NightShiftSettingsStore: NightShiftSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.nightShift", namespace: namespace)
    }

    public func load() -> NightShiftSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(NightShiftSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: NightShiftSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Observable model

/// Owns the Night Shift settings for the active profile and computes the live
/// per-channel multiply the overlay paints. Mirrors `ThemeSettingsModel`: it
/// persists `settings` to its `NightShiftSettingsStore` and broadcasts changes
/// via `@Observable`. A one-minute timer nudges `tick` so the intensity
/// re-evaluates as the evening progresses.
@MainActor
@Observable
public final class NightShiftSettingsModel {
    /// The persisted selections. Mutating any field (directly or via a SwiftUI
    /// binding) saves the whole blob.
    public var settings: NightShiftSettings {
        didSet { store.save(settings) }
    }

    /// When true (set while the Night Shift settings screen calibrates), the ramp
    /// is bypassed and the overlay paints at full strength so the user can see
    /// what their chosen Dimness/Warmth looks like at deep night.
    public var isPreviewing: Bool = false

    /// Simulated clock driven by `runDayNightPreview()`. While non-nil it overrides
    /// the live time so the overlay sweeps a whole day → night → day in a few
    /// seconds. `previewProgress` (0…1) tracks how far through that sweep we are.
    public var previewDate: Date?
    public var previewProgress: Double?

    /// The set of fade durations (in minutes) the UI steps through.
    public static let fadeOptions: [Int] = [15, 30, 45, 60, 90, 120, 180, 240, 300]

    /// Minute granularity the manual on/off time steppers nudge by.
    public static let manualStepMinutes = 15

    private let store: NightShiftSettingsStoring
    /// Bumped by the timer so time-derived values recompute.
    private var tick: Date = .init()

    /// Owns the live RunLoop timers off the actor so they can be torn down from
    /// a `deinit` without touching main-actor-isolated state under strict
    /// concurrency. A new model is built on every profile switch, so the timers
    /// must not leak when the old model is discarded.
    private final class TimerBox: @unchecked Sendable {
        var tick: Timer?
        var preview: Timer?

        func invalidateAll() {
            tick?.invalidate()
            tick = nil
            preview?.invalidate()
            preview = nil
        }

        deinit {
            let tick = self.tick
            let preview = self.preview
            let drop = {
                tick?.invalidate()
                preview?.invalidate()
            }
            if Thread.isMainThread {
                drop()
            } else {
                DispatchQueue.main.async(execute: drop)
            }
        }
    }

    private let timers = TimerBox()
    private var previewStart: Date = .init()
    private var previewStep = 0
    private static let previewSteps = 180

    public init(store: NightShiftSettingsStoring = NightShiftSettingsStore()) {
        self.store = store
        self.settings = store.load()

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.tick = timer
    }

    // MARK: Transition timing

    /// How long the wash takes to fade fully in after the on-event / out before
    /// the off-event.
    private var transitionInterval: TimeInterval { Double(settings.fadeMinutes) * 60 }

    // MARK: Resolved values

    public var region: NightShiftRegion {
        NightShiftRegion.region(id: settings.regionID) ?? NightShiftRegion.guessFromCurrentTimeZone()
    }

    /// Time zone the schedule is reckoned in: the region's zone in Auto mode, the
    /// device's local zone for manually-entered clock times.
    public var activeTimeZone: TimeZone {
        switch settings.scheduleMode {
        case .solar: return region.timeZone
        case .manual, .alwaysOn: return .current
        }
    }

    /// Short human label for the current fade duration, e.g. "90m", "1h", "1.5h".
    public var fadeDescription: String { Self.fadeLabel(minutes: settings.fadeMinutes) }

    public static func fadeLabel(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = Double(minutes) / 60
        return hours == hours.rounded()
            ? "\(Int(hours))h"
            : String(format: "%.1fh", hours)
    }

    /// Formats a minutes-since-midnight value as a clock time in `timeZone`.
    public func clockLabel(minutes: Int, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let normalized = ((minutes % 1440) + 1440) % 1440
        let base = calendar.startOfDay(for: Date())
        let date = calendar.date(byAdding: .minute, value: normalized, to: base) ?? base
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    /// 0…1 ramp for the current moment (0 by day, 1 deep at night). A running
    /// day-preview sweep wins; otherwise full strength while calibrating in
    /// Settings; otherwise the real schedule.
    public var currentIntensity: Double {
        guard settings.isEnabled else { return 0 }
        if let previewDate { return intensity(at: previewDate) }
        if isPreviewing { return 1 }
        return intensity(at: tick)
    }

    /// Simulated wall-clock label (in the active time zone) for the preview sweep,
    /// e.g. "9:24 PM"; empty when no sweep is running.
    public var previewClockText: String {
        guard let previewDate else { return "" }
        let formatter = DateFormatter()
        formatter.timeZone = activeTimeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: previewDate)
    }

    /// Opacity of the **black dimming layer** right now (brightness reduction).
    public var currentDimOpacity: Double {
        currentIntensity * settings.dimness.peakOpacity
    }

    /// Opacity of the **warm color layer** right now (hue cast).
    public var currentWarmOpacity: Double {
        currentIntensity * settings.warmth.peakOpacity
    }

    /// The per-channel multiply scalars the overlay multiplies the whole app by
    /// right now. White by day (×1, invisible), redder as night deepens.
    ///
    ///     r = 1 − dim
    ///     g = (1 − dim) × (1 − warm × greenKill)
    ///     b = (1 − dim) × (1 − warm)
    public var channelScalars: NightShiftChannelScalars {
        let dim = currentDimOpacity
        let warm = currentWarmOpacity
        let red = 1 - dim
        let green = (1 - dim) * (1 - warm * settings.warmth.greenKill)
        let blue = (1 - dim) * (1 - warm)
        return NightShiftChannelScalars(red: red, green: green, blue: blue)
    }

    /// Whether the overlay is painting anything right now.
    public var isActiveNow: Bool { currentDimOpacity > 0.001 || currentWarmOpacity > 0.001 }

    // MARK: Day preview

    /// Animate a full midnight → midnight day in `duration` seconds, sweeping the
    /// overlay through the active schedule's ramp so the viewer can watch how it
    /// warms and dims across a day, then return to live.
    public func runDayNightPreview(duration: TimeInterval = 9) {
        guard settings.isEnabled else { return }
        timers.preview?.invalidate()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = activeTimeZone
        previewStart = calendar.startOfDay(for: Date())
        previewStep = 0
        previewProgress = 0
        previewDate = previewStart

        let stepInterval = duration / Double(Self.previewSteps)
        let timer = Timer(timeInterval: stepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advancePreview() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.preview = timer
    }

    private func advancePreview() {
        previewStep += 1
        let fraction = min(Double(previewStep) / Double(Self.previewSteps), 1)
        previewProgress = fraction
        previewDate = previewStart.addingTimeInterval(24 * 60 * 60 * fraction)
        if fraction >= 1 {
            timers.preview?.invalidate()
            timers.preview = nil
            previewProgress = nil
            previewDate = nil
        }
    }

    // MARK: Schedule summary

    /// A human-readable status line for Settings, covering both schedule modes.
    public func scheduleSummary(now: Date = Date()) -> String {
        let fade = fadeDescription
        switch settings.scheduleMode {
        case .alwaysOn:
            if !settings.isEnabled {
                return "Off. Set to always on."
            }
            return "Always on. Tints the screen at full strength around the clock."

        case .manual:
            let on = clockLabel(minutes: settings.manualOnMinutes)
            let off = clockLabel(minutes: settings.manualOffMinutes)
            if !settings.isEnabled {
                return "Off. Manual: on \(on), off \(off)."
            }
            if isActiveNow {
                let percent = Int((currentIntensity * 100).rounded())
                return "Active now (\(percent)%). Manual: on \(on), off \(off) · \(fade) fade."
            }
            return "Idle until \(on). Manual · \(fade) fade."

        case .solar:
            let region = self.region
            let tz = region.timeZone
            guard let today = SolarTime.sunriseSunset(
                latitude: region.latitude, longitude: region.longitude, on: now, timeZone: tz
            ) else {
                return "Sunrise/sunset unavailable at this location today."
            }

            let formatter = DateFormatter()
            formatter.timeZone = tz
            formatter.dateFormat = "h:mm a"

            let sunset = formatter.string(from: today.sunset)
            let sunrise = formatter.string(from: today.sunrise)

            if !settings.isEnabled {
                return "Off. \(region.name): sunset \(sunset), sunrise \(sunrise)."
            }
            if isActiveNow {
                let percent = Int((currentIntensity * 100).rounded())
                return "Active now (\(percent)%). \(region.name) sunrise \(sunrise) · \(fade) fade."
            }
            return "Idle until sunset (\(sunset)) in \(region.name) · \(fade) fade."
        }
    }

    // MARK: Ramp math

    private func intensity(at date: Date) -> Double {
        switch settings.scheduleMode {
        case .manual:
            return manualIntensity(at: date)
        case .solar:
            return solarIntensity(at: date)
        case .alwaysOn:
            return 1
        }
    }

    /// Ramp driven by the viewer's two fixed clock times (local zone), handling
    /// the usual case where the window wraps past midnight.
    private func manualIntensity(at date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let startOfToday = calendar.startOfDay(for: date)
        // The active window may have started today or yesterday (when it wraps
        // midnight), so test both candidate start days.
        for dayOffset in [0, -1] {
            guard
                let base = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                let on = calendar.date(byAdding: .minute, value: settings.manualOnMinutes, to: base),
                let rawOff = calendar.date(byAdding: .minute, value: settings.manualOffMinutes, to: base)
            else { continue }
            let off = rawOff <= on ? rawOff.addingTimeInterval(86_400) : rawOff
            if date >= on, date < off {
                return ramp(now: date, dusk: on, dawn: off)
            }
        }
        return 0
    }

    private func solarIntensity(at date: Date) -> Double {
        let region = self.region
        let tz = region.timeZone
        guard let today = SolarTime.sunriseSunset(
            latitude: region.latitude, longitude: region.longitude, on: date, timeZone: tz
        ) else {
            return 0
        }

        if date < today.sunrise {
            // Pre-dawn: the night began at yesterday's sunset.
            let yesterday = SolarTime.sunriseSunset(
                latitude: region.latitude,
                longitude: region.longitude,
                on: date.addingTimeInterval(-86_400),
                timeZone: tz
            )
            let dusk = yesterday?.sunset ?? today.sunset.addingTimeInterval(-86_400)
            return ramp(now: date, dusk: dusk, dawn: today.sunrise)
        } else if date < today.sunset {
            // Daytime.
            return 0
        } else {
            // After dusk: the night ends at tomorrow's sunrise.
            let tomorrow = SolarTime.sunriseSunset(
                latitude: region.latitude,
                longitude: region.longitude,
                on: date.addingTimeInterval(86_400),
                timeZone: tz
            )
            let dawn = tomorrow?.sunrise ?? today.sunrise.addingTimeInterval(86_400)
            return ramp(now: date, dusk: today.sunset, dawn: dawn)
        }
    }

    /// Triangle-clamped ramp: 0 at `dusk`, up over `transitionInterval`, hold at
    /// 1, down over `transitionInterval` to 0 at `dawn`. Taking the min of the two
    /// legs also gracefully handles windows shorter than `2 × transitionInterval`
    /// (the wash simply peaks below full strength).
    private func ramp(now: Date, dusk: Date, dawn: Date) -> Double {
        guard now > dusk, now < dawn else { return 0 }
        let interval = max(transitionInterval, 1)
        let up = now.timeIntervalSince(dusk) / interval
        let down = dawn.timeIntervalSince(now) / interval
        return Swift.max(0, Swift.min(1, Swift.min(up, down)))
    }
}
