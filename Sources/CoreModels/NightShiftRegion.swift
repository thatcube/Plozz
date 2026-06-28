import Foundation

/// A pickable location for Night Shift's sunrise/sunset schedule.
///
/// Apple TV has no GPS and CoreLocation there is coarse and needs a permission
/// prompt, so instead of asking the system where it is we let the viewer pick a
/// nearby city. Each region carries an IANA time-zone identifier (also its `id`)
/// plus coordinates, which is everything `SolarTime` needs.
public struct NightShiftRegion: Identifiable, Equatable, Hashable, Sendable {
    /// IANA time-zone identifier, e.g. `"America/New_York"`. Doubles as the
    /// stable persistence id.
    public let id: String
    /// Human-facing label shown in the picker.
    public let name: String
    public let latitude: Double
    public let longitude: Double

    public init(id: String, name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    public var timeZone: TimeZone { TimeZone(identifier: id) ?? .current }
}

extension NightShiftRegion {
    /// A curated, globe-spanning set of cities (one per common time-zone offset
    /// and latitude band). Not exhaustive — just enough that almost everyone can
    /// pick somewhere within a few hundred km, which is plenty for a tint ramp.
    public static let catalog: [NightShiftRegion] = [
        .init(id: "Pacific/Honolulu", name: "Honolulu", latitude: 21.31, longitude: -157.86),
        .init(id: "America/Anchorage", name: "Anchorage", latitude: 61.22, longitude: -149.90),
        .init(id: "America/Los_Angeles", name: "Los Angeles", latitude: 34.05, longitude: -118.24),
        .init(id: "America/Phoenix", name: "Phoenix", latitude: 33.45, longitude: -112.07),
        .init(id: "America/Denver", name: "Denver", latitude: 39.74, longitude: -104.99),
        .init(id: "America/Chicago", name: "Chicago", latitude: 41.88, longitude: -87.63),
        .init(id: "America/Mexico_City", name: "Mexico City", latitude: 19.43, longitude: -99.13),
        .init(id: "America/New_York", name: "New York", latitude: 40.71, longitude: -74.01),
        .init(id: "America/Toronto", name: "Toronto", latitude: 43.65, longitude: -79.38),
        .init(id: "America/Halifax", name: "Halifax", latitude: 44.65, longitude: -63.57),
        .init(id: "America/Bogota", name: "Bogotá", latitude: 4.71, longitude: -74.07),
        .init(id: "America/Sao_Paulo", name: "São Paulo", latitude: -23.55, longitude: -46.63),
        .init(id: "America/Argentina/Buenos_Aires", name: "Buenos Aires", latitude: -34.60, longitude: -58.38),
        .init(id: "Atlantic/Reykjavik", name: "Reykjavík", latitude: 64.15, longitude: -21.94),
        .init(id: "Europe/Dublin", name: "Dublin", latitude: 53.35, longitude: -6.26),
        .init(id: "Europe/London", name: "London", latitude: 51.51, longitude: -0.13),
        .init(id: "Europe/Lisbon", name: "Lisbon", latitude: 38.72, longitude: -9.14),
        .init(id: "Europe/Madrid", name: "Madrid", latitude: 40.42, longitude: -3.70),
        .init(id: "Europe/Paris", name: "Paris", latitude: 48.86, longitude: 2.35),
        .init(id: "Europe/Amsterdam", name: "Amsterdam", latitude: 52.37, longitude: 4.90),
        .init(id: "Europe/Berlin", name: "Berlin", latitude: 52.52, longitude: 13.40),
        .init(id: "Europe/Rome", name: "Rome", latitude: 41.90, longitude: 12.50),
        .init(id: "Europe/Stockholm", name: "Stockholm", latitude: 59.33, longitude: 18.07),
        .init(id: "Europe/Athens", name: "Athens", latitude: 37.98, longitude: 23.73),
        .init(id: "Europe/Helsinki", name: "Helsinki", latitude: 60.17, longitude: 24.94),
        .init(id: "Europe/Moscow", name: "Moscow", latitude: 55.76, longitude: 37.62),
        .init(id: "Africa/Lagos", name: "Lagos", latitude: 6.52, longitude: 3.38),
        .init(id: "Africa/Cairo", name: "Cairo", latitude: 30.04, longitude: 31.24),
        .init(id: "Africa/Nairobi", name: "Nairobi", latitude: -1.29, longitude: 36.82),
        .init(id: "Africa/Johannesburg", name: "Johannesburg", latitude: -26.20, longitude: 28.05),
        .init(id: "Asia/Jerusalem", name: "Jerusalem", latitude: 31.78, longitude: 35.22),
        .init(id: "Asia/Dubai", name: "Dubai", latitude: 25.20, longitude: 55.27),
        .init(id: "Asia/Karachi", name: "Karachi", latitude: 24.86, longitude: 67.01),
        .init(id: "Asia/Kolkata", name: "India (Kolkata)", latitude: 22.57, longitude: 88.36),
        .init(id: "Asia/Dhaka", name: "Dhaka", latitude: 23.81, longitude: 90.41),
        .init(id: "Asia/Bangkok", name: "Bangkok", latitude: 13.76, longitude: 100.50),
        .init(id: "Asia/Jakarta", name: "Jakarta", latitude: -6.21, longitude: 106.85),
        .init(id: "Asia/Singapore", name: "Singapore", latitude: 1.35, longitude: 103.82),
        .init(id: "Asia/Manila", name: "Manila", latitude: 14.60, longitude: 120.98),
        .init(id: "Asia/Hong_Kong", name: "Hong Kong", latitude: 22.32, longitude: 114.17),
        .init(id: "Asia/Shanghai", name: "Shanghai", latitude: 31.23, longitude: 121.47),
        .init(id: "Asia/Seoul", name: "Seoul", latitude: 37.57, longitude: 126.98),
        .init(id: "Asia/Tokyo", name: "Tokyo", latitude: 35.68, longitude: 139.69),
        .init(id: "Australia/Perth", name: "Perth", latitude: -31.95, longitude: 115.86),
        .init(id: "Australia/Adelaide", name: "Adelaide", latitude: -34.93, longitude: 138.60),
        .init(id: "Australia/Brisbane", name: "Brisbane", latitude: -27.47, longitude: 153.03),
        .init(id: "Australia/Sydney", name: "Sydney", latitude: -33.87, longitude: 151.21),
        .init(id: "Pacific/Auckland", name: "Auckland", latitude: -36.85, longitude: 174.76),
        .init(id: "Pacific/Fiji", name: "Suva", latitude: -18.14, longitude: 178.44),
    ]

    /// Catalog sorted for display (by label).
    public static let sortedCatalog: [NightShiftRegion] = catalog.sorted { $0.name < $1.name }

    /// Looks a region up by its persisted id.
    public static func region(id: String) -> NightShiftRegion? {
        catalog.first { $0.id == id }
    }

    /// Best-effort default from the device's current time zone: an exact IANA
    /// match if we carry that city, otherwise the catalog city whose *current*
    /// UTC offset matches (so at least the schedule lands in the right part of
    /// the day), otherwise London as a neutral fallback.
    public static func guessFromCurrentTimeZone() -> NightShiftRegion {
        let current = TimeZone.current
        if let exact = region(id: current.identifier) { return exact }

        let now = Date()
        let offset = current.secondsFromGMT(for: now)
        if let sameOffset = catalog.first(where: {
            $0.timeZone.secondsFromGMT(for: now) == offset
        }) {
            return sameOffset
        }
        return region(id: "Europe/London") ?? catalog[0]
    }
}

/// Pure sunrise/sunset math (no network, no CoreLocation) used by Night Shift to
/// ramp its warm tint against the real sun. It's a compact port of the standard
/// "sunrise equation" (NOAA's solar-position approximation) and is accurate to
/// about a minute for the latitudes people actually live at — more than enough
/// to fade a screen tint in and out.
public enum SolarTime {
    /// Sunrise and sunset (as absolute `Date`s) for the local calendar day that
    /// contains `reference` at the given coordinates.
    ///
    /// Returns `nil` for polar day / polar night, where the sun never crosses the
    /// horizon on that date (the caller treats that as "no transition today").
    ///
    /// - Parameters:
    ///   - latitude: Degrees north (negative = south).
    ///   - longitude: Degrees east (negative = west).
    ///   - reference: Any instant within the day of interest.
    ///   - timeZone: The location's time zone, used only to pick which calendar
    ///     day `reference` falls on. The returned `Date`s are absolute, so they
    ///     compare correctly against `Date()` regardless of zone.
    public static func sunriseSunset(
        latitude: Double,
        longitude: Double,
        on reference: Date,
        timeZone: TimeZone
    ) -> (sunrise: Date, sunset: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.year, .month, .day], from: reference)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }

        // Julian Day Number for the calendar date (Fliegel–Van Flandern).
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        let jdn = Double(
            day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
        )

        let rad = Double.pi / 180
        let deg = 180 / Double.pi

        // Days since 2000-01-01 12:00 TT (the 0.0008 term folds in leap seconds).
        let n = (jdn - 2451545.0 + 0.0008).rounded()
        // Mean solar noon (east-positive longitude advances the clock).
        let meanNoon = n - longitude / 360.0
        // Solar mean anomaly.
        let anomaly = (357.5291 + 0.98560028 * meanNoon).truncatingRemainder(dividingBy: 360)
        let anomalyR = anomaly * rad
        // Equation of the center.
        let center = 1.9148 * sin(anomalyR) + 0.0200 * sin(2 * anomalyR) + 0.0003 * sin(3 * anomalyR)
        // Ecliptic longitude of the sun.
        let lambda = (anomaly + center + 282.9372).truncatingRemainder(dividingBy: 360)
        let lambdaR = lambda * rad
        // Solar transit (local solar noon, in Julian days).
        let transit = 2451545.0 + meanNoon + 0.0053 * sin(anomalyR) - 0.0069 * sin(2 * lambdaR)
        // Sun's declination.
        let declination = asin(sin(lambdaR) * sin(23.4397 * rad))
        // Hour angle at the horizon, with the standard −0.833° refraction/disc term.
        let cosHourAngle =
            (sin(-0.833 * rad) - sin(latitude * rad) * sin(declination)) /
            (cos(latitude * rad) * cos(declination))
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }
        let hourAngle = acos(cosHourAngle) * deg

        let sunset = transit + hourAngle / 360.0
        let sunrise = transit - hourAngle / 360.0

        return (date(fromJulian: sunrise), date(fromJulian: sunset))
    }

    /// Converts a Julian date to a Foundation `Date` (2440587.5 = Unix epoch).
    private static func date(fromJulian julian: Double) -> Date {
        Date(timeIntervalSince1970: (julian - 2440587.5) * 86400.0)
    }
}
