#if os(iOS)
import CoreModels
import Foundation
import Observation
import SwiftUI

/// Drives the iPhone/iPad build to a named screen so a capture run can photograph
/// it, the iOS counterpart of the tvOS `ScreenshotDirector`.
///
/// The two shells share no code — iOS is `PlozziOSAppModel`, tvOS is `AppState` —
/// so the mechanism is restated here rather than imported. The design is the
/// same, and deliberately so: a screen is asked for BY NAME, never by simulating
/// taps. The capture script drops a request into the app's own container:
///
/// ```
/// echo 'detail?title=Oppenheimer' > "$container/Documents/.plozz-shots-request"
/// ```
///
/// and the app searches its real libraries for that title and pushes its page —
/// the same push a tap makes, through the same navigation environment. Nothing is
/// simulated and no private state is photographed; the screen is real, it is just
/// reached deterministically.
///
/// A file rather than `simctl openurl` because iOS puts an "Open in Plozz?"
/// confirmation in front of a custom-scheme URL, and there is no way to dismiss a
/// system alert without a UI test driving the device — which is the machinery this
/// exists to avoid. The container is writable from the host, so a file needs no
/// such permission.
///
/// Requests are acknowledged by writing the outcome to `.plozz-shots-ack` **once
/// the screen has been reached** — not once the request has been parsed. That
/// distinction is the whole value of the ack: acknowledging a parse made a run
/// that could not find a title report success and photograph whatever page
/// happened to still be up.
///
/// Inert in release: ``handle(url:)`` is compiled to `return false` outside DEBUG
/// and ``startWatchingForRequests()`` is a no-op, so a shipped build cannot be
/// steered and never starts a timer.
@MainActor
@Observable
final class PlozziOSScreenshotDirector {
    /// What the capture script last asked for. The router leaf in
    /// `PlozziOSHomeView` watches this, performs it, then clears it so the same
    /// request can be asked for again later in the session.
    var request: Request?

    /// The tab the capture script last asked for, held separately because a tab
    /// change is performed by the tab shell rather than by the Home stack.
    var tab: String?

    // MARK: Routing seams
    //
    // The leaf that performs a request lives OUTSIDE the navigation stacks, in
    // the tab shell's background. A router placed on the Home screen itself
    // stopped answering the instant the first pushed detail page covered it —
    // SwiftUI fired the root's `onDisappear` and cancelled the router's `.task`,
    // so every request after the first was consumed but never acked. The screens
    // that actually own the pushes and the player hand their seams up to here, so
    // the always-mounted router can reach them without living inside a stack.
    //
    // Not observed: these are imperative one-time registrations, and tracking
    // them would invalidate the tab shell every time a screen re-registered.
    // Only the Home stack registers the pushes, so a detail/person/library/play
    // request has to be photographed with the Home tab selected. A request that
    // arrived while Search was up pushed the page onto the Home stack underneath
    // the still-visible Search tab, and the shot was of Search — so every push
    // brings the Home tab forward first.
    @ObservationIgnored var selectHomeTab: (() -> Void)?
    @ObservationIgnored var navigateToItem: ((MediaItem) -> Void)?
    @ObservationIgnored var navigateToPerson: ((MediaPerson, String?) -> Void)?
    @ObservationIgnored var navigateToLibrary: ((PlozziOSLibraryRoute) -> Void)?
    @ObservationIgnored var resetNavigation: (() -> Void)?
    @ObservationIgnored var startPlayback: ((MediaItem, Double) -> Void)?
    @ObservationIgnored var dismissPlayback: (() -> Void)?

    // Bumped by a pushed page as it appears. The router acks a navigation only
    // after this moves past the value it read before it pushed, because setting
    // the navigation state does not put the page on screen — the enrichment pass
    // stalls the main actor for whole seconds, and in that gap the host settled
    // on and photographed the page the push was leaving. Waiting for the page to
    // actually mount is the only signal that the old one is gone.
    @ObservationIgnored var pageArrivals = 0

    /// Records the arrival count so a following ``awaitArrival(after:)`` can tell
    /// a fresh page apart from the one already on screen.
    func arrivalCheckpoint() -> Int { pageArrivals }

    /// Returns once a page has appeared since `checkpoint`, or after a cutoff so a
    /// push that never mounts a page (a dead-end route) still acks rather than
    /// hanging the whole run.
    func awaitArrival(after checkpoint: Int) async {
        for _ in 0..<60 {
            if pageArrivals > checkpoint { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Called by each pushed page from its `onAppear`.
    func notePageArrival() { pageArrivals += 1 }

    init() {}

    // MARK: File channel

    /// `Documents` rather than `tmp` because the simulator can clear `tmp` between
    /// launches, and this has to survive the app being relaunched mid-session.
    private static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static let requestFile = ".plozz-shots-request"
    private static let ackFile = ".plozz-shots-ack"

    private var poll: Task<Void, Never>?
    private var ackURL: URL?

    /// Reports the outcome of the request that was just performed. Called by the
    /// routers once they have finished — see the note above about why this is not
    /// written when the request is parsed.
    func finish(_ outcome: Outcome) {
        finish(outcome.rawValue)
    }

    /// Reports the outcome of the request that was just performed, or answers a
    /// probe. Free-form text rather than an enum because a probe's answer is a
    /// list of titles.
    func finish(_ text: String) {
        guard let ackURL else { return }
        try? text.write(to: ackURL, atomically: true, encoding: .utf8)
    }

    enum Outcome: String, Sendable {
        /// The screen was reached.
        case ok
        /// The library had no match for the requested title/person/library.
        case notFound
    }

    /// Starts watching for requests. A no-op unless the capture rig asked for a
    /// seeded launch, so a normal debug run never starts a timer.
    func startWatchingForRequests() {
        #if DEBUG
        guard poll == nil,
              ProcessInfo.processInfo.environment["PLOZZ_SHOTS_NFS_HOST"] != nil,
              let directory = Self.directory
        else { return }

        let request = directory.appendingPathComponent(Self.requestFile)
        ackURL = directory.appendingPathComponent(Self.ackFile)
        // Polling rather than a `DispatchSource` file watcher: the host writes the
        // file by creating it, and a watcher has to be re-armed every time its
        // target is replaced. At this cadence the difference is not worth the
        // re-arming bug it would cost.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let line = try? String(contentsOf: request, encoding: .utf8) else { continue }
                try? FileManager.default.removeItem(at: request)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self,
                      !trimmed.isEmpty,
                      let url = URL(string: "plozz://shots/" + trimmed)
                else { continue }
                self.handle(url: url)
            }
        }
        #endif
    }

    enum Request: Equatable, Sendable {
        /// Pop to the root of the Home stack and dismiss the player.
        case home
        /// Push the detail page for the best match of `title`.
        case detail(title: String)
        /// Push the person page for `person` in the cast of `title`'s best match.
        case person(title: String, person: String)
        /// Push the library grid whose name best matches, or the first library.
        case library(name: String?)
        /// Report what the library actually calls things matching `title`.
        /// Answered in the ack, so the shot list can be written against the names
        /// the library really has rather than the ones it ought to.
        case probe(title: String)
        /// Play the best match of `title`, starting `seconds` in.
        case play(title: String, seconds: Double)
    }

    // MARK: URL

    /// Parses `plozz://shots/<verb>?…`, returning `true` when the URL was ours.
    @discardableResult
    func handle(url: URL) -> Bool {
        #if !DEBUG
        return false
        #else
        guard url.scheme == "plozz",
              url.host == "shots",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }

        let verb = components.path.split(separator: "/").first.map(String.init) ?? ""
        let query = { (name: String) -> String? in
            components.queryItems?.first { $0.name == name }?.value
        }

        switch verb {
        case "home":
            request = .home
        case "detail":
            guard let title = query("title") else { return false }
            request = .detail(title: title)
        case "person":
            guard let title = query("title"), let person = query("person") else { return false }
            request = .person(title: title, person: person)
        case "library":
            request = .library(name: query("name"))
        case "probe":
            guard let title = query("title") else { return false }
            request = .probe(title: title)
        case "play":
            guard let title = query("title") else { return false }
            request = .play(title: title, seconds: query("at").flatMap(Double.init) ?? 0)
        case "tab":
            guard let name = query("name") else { return false }
            tab = name
        default:
            return false
        }
        return true
        #endif
    }
}

/// Seeds a media share from the environment so an automated capture run starts on
/// a populated Home instead of the onboarding flow, the iOS counterpart of the
/// tvOS `ScreenshotSeed`.
///
/// Screenshot automation needs the app in a known, signed-in state. Driving the
/// onboarding UI to get there is slow and brittle. Seeding the share directly
/// reuses the exact code path onboarding calls (`addNFSShare`), so the resulting
/// state is identical to a hand-added share.
///
/// DEBUG-only and inert unless the environment asks for it, so nothing here can
/// reach a shipped build or change a normal run.
///
/// Used by `tools/capture-shots.sh --platform ios`:
/// ```
/// PLOZZ_SHOTS_NFS_HOST=192.168.68.71
/// PLOZZ_SHOTS_NFS_EXPORT=/mnt/user/Media
/// PLOZZ_SHOTS_NFS_NAME=Brandoland
/// ```
enum PlozziOSScreenshotSeed {
    /// Applies the seed if the environment provides one and the app has no
    /// accounts yet. Idempotent: a second launch finds the share already there and
    /// leaves the scanned catalog alone, which is what keeps repeat capture runs
    /// fast.
    ///
    /// Adding the first share starts the one-time first-run chain. Unlike tvOS's
    /// two steps, iOS runs four: a library-selection sheet, then profile → seerr →
    /// theme. All are completed here through the same calls their buttons make, so
    /// a capture run lands on Home rather than onboarding, and they never reappear
    /// next launch. The library step is presented after a `Task.yield`, so the
    /// completion is driven from a short polling task rather than inline.
    @MainActor
    static func applyIfRequested(to appModel: PlozziOSAppModel) {
        #if DEBUG
        // Start listening first: a repeat run finds the share already there and
        // returns below, but it still needs to be drivable.
        appModel.screenshotDirector.startWatchingForRequests()

        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["PLOZZ_SHOTS_NFS_HOST"],
              let export = environment["PLOZZ_SHOTS_NFS_EXPORT"],
              !host.isEmpty,
              !export.isEmpty
        else { return }

        guard appModel.accounts.isEmpty else { return }

        let port = environment["PLOZZ_SHOTS_NFS_PORT"].flatMap(Int.init)
        let name = environment["PLOZZ_SHOTS_NFS_NAME"] ?? ""

        guard appModel.addNFSShare(
            host: host,
            port: port,
            exportPath: export,
            displayName: name
        ) else { return }

        // The library-selection step is scheduled through a `Task.yield`, so it is
        // not on screen the instant the share lands. Wait for it (or for setup to
        // have completed some other way), complete it, then walk the remaining
        // synchronous steps — each only sets the next `pendingFirstRunStep`.
        Task { @MainActor in
            for _ in 0..<100 {
                if appModel.pendingLibrarySelection != nil
                    || appModel.profiles.firstRunProfileSetupComplete {
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if appModel.pendingLibrarySelection != nil {
                appModel.completeLibrarySelection()
            }
            guard !appModel.profiles.firstRunProfileSetupComplete else { return }
            appModel.confirmFirstRunProfile()
            appModel.completeFirstRunSeerrSetup()
            appModel.finishFirstRunThemeSelection()
        }
        #endif
    }

    /// Whether the capture rig asked the player to keep its transport bar open.
    ///
    /// The transport is the part of the player worth photographing — title,
    /// scrubber, elapsed/remaining, and the Info/Cast/subtitle affordances — and
    /// it is also the part that is deliberately hard to catch: it appears on input
    /// and hides a few seconds later, and a run driven by files rather than by
    /// touch never supplies that input. `PlozziOSPlayerControlsOverlay` reads this
    /// to suppress its auto-hide, so the bar the run set up stays up long enough
    /// to photograph.
    ///
    /// DEBUG-only, and only when the capture environment asked for a seeded run,
    /// so an ordinary session's controls behave exactly as they always have.
    static var holdsPlayerControls: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["PLOZZ_SHOTS_NFS_HOST"] != nil
            && environment["PLOZZ_SHOTS_HOLD_CONTROLS"] == "1"
        #else
        return false
        #endif
    }
}
#endif
