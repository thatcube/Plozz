#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The shared body of every season-request picker — "Request All …" (when more
/// than one season is requestable) followed by one row per season: a tappable
/// **Request S{n}** for a missing season, or a disabled status row for an
/// in-flight / failed one. Placed inside a `Menu { }` on both platforms (tvOS +
/// iOS, home hero + detail) so the picker reads identically everywhere and the
/// season logic lives in exactly one place.
public struct SeasonRequestMenuContent: View {
    private let availability: MediaRequestAvailability
    private let requestAllTitle: String
    private let onRequest: ([Int]) -> Void

    public init(
        availability: MediaRequestAvailability,
        requestAllTitle: String = "Request All Seasons",
        onRequest: @escaping ([Int]) -> Void
    ) {
        self.availability = availability
        self.requestAllTitle = requestAllTitle
        self.onRequest = onRequest
    }

    private var seasons: [MediaSeasonRequestState] {
        availability.requestPickerSeasons
    }

    private var requestableSeasons: [MediaSeasonRequestState] {
        seasons.filter(\.isRequestable)
    }

    public var body: some View {
        if requestableSeasons.count > 1 {
            Button(requestAllTitle) {
                onRequest(requestableSeasons.map(\.number))
            }
            Divider()
        }
        ForEach(seasons) { season in
            if season.requestFailed {
                Label("\(season.title) — Failed", systemImage: "exclamationmark.circle")
            } else if season.isRequestable {
                Button("Request \(season.title)") {
                    onRequest([season.number])
                }
            } else {
                Label(
                    "\(season.title) — \(statusText(for: season))",
                    systemImage: season.status == .processing
                        ? "arrow.down.circle"
                        : "clock"
                )
            }
        }
    }

    private func statusText(for season: MediaSeasonRequestState) -> String {
        season.status == .processing ? "Processing" : "Requested"
    }
}
#endif
