import Foundation
import Observation

/// Drives the app to a named screen so a capture run can photograph it.
///
/// The obvious way to reach a screen in a UI test is to press the remote until
/// focus lands somewhere useful and then press Select. On tvOS that is a bad
/// bet: the focus engine moves one cell at a time, the number of presses
/// depends on what the library happens to contain, and the shelf order changes
/// as soon as something is watched. A capture run that walks focus is a capture
/// run that silently photographs the wrong title.
///
/// So navigation is asked for by name instead. The capture script drops a
/// request into the app's own container:
///
/// ```
/// echo 'detail?title=Oppenheimer' > "$container/Documents/.plozz-shots-request"
/// ```
///
/// and the app searches its own libraries for that title and pushes its page —
/// the same push a tap would make, through the same `navigate`. Nothing is
/// simulated and no private state is photographed; the screen is real, it is
/// just reached deterministically.
///
/// A file rather than the obvious `plozz://` URL because tvOS puts an "Open in
/// Plozz?" confirmation in front of `simctl openurl`, and there is no way to
/// dismiss a system alert without a UI test driving the remote — which is the
/// machinery this exists to avoid. The container is writable from the host
/// (`simctl get_app_container`), so a file needs no such permission. The URL
/// form is still accepted, because it is handy when driving a run by hand.
///
/// Requests are acknowledged by writing the outcome to `.plozz-shots-ack`
/// **once the screen has been reached** — not once the request has been parsed.
/// That distinction is the whole value of the ack: acknowledging a parse made
/// a run that could not find "The Lord of the Rings" report success and
/// photograph whatever page happened to still be up.
///
/// One launch serves a whole capture session: request a screen, wait for the
/// ack, wait for it to settle, screenshot the framebuffer, request the next. No
/// XCTest, no test host, and no re-scan between screens.
///
/// Inert in release: ``handle(url:)`` is compiled to `return false` outside
/// DEBUG, so a shipped build cannot be steered by a URL. The type itself stays
/// unconditional only so the call sites that hold it need no `#if` — a
/// conditionally-compiled stored property has to be threaded through every
/// initializer in between, and that noise is worse than an unreachable enum.
@MainActor
@Observable
public final class ScreenshotDirector {
    /// What the capture script last asked for. The router leaf in `HomeTab`
    /// watches this, performs it, then clears it so the same request can be
    /// asked for again later in the session.
    public var request: Request?

    /// The tab the capture script last asked for, held separately because a tab
    /// change is performed by `MainTabView` rather than by the Home stack.
    public var tab: String?

    public init() {}

    // MARK: File channel

    /// Where the host drops a request, and where the app answers.
    ///
    /// `Documents` rather than `tmp` because the simulator can clear `tmp`
    /// between launches, and this has to survive the app being relaunched
    /// mid-session.
    private static var directory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static let requestFile = ".plozz-shots-request"
    private static let ackFile = ".plozz-shots-ack"

    private var poll: Task<Void, Never>?
    private var ackURL: URL?

    /// Reports the outcome of the request that was just performed. Called by
    /// the routers in `HomeTab`/`MainTabView` once they have finished — see the
    /// note above about why this is not written when the request is parsed.
    public func finish(_ outcome: Outcome) {
        finish(outcome.rawValue)
    }

    /// Reports the outcome of the request that was just performed, or answers
    /// a probe. Free-form text rather than an enum because a probe's answer is
    /// a list of titles.
    public func finish(_ text: String) {
        guard let ackURL else { return }
        try? text.write(to: ackURL, atomically: true, encoding: .utf8)
    }

    public enum Outcome: String, Sendable {
        /// The screen was reached.
        case ok
        /// The library had no match for the requested title/person/library.
        case notFound
    }

    /// Starts watching for requests. Called once the app reaches its signed-in
    /// root; a no-op unless the capture rig asked for a seeded launch, so a
    /// normal debug run never starts a timer.
    public func startWatchingForRequests() {
        #if DEBUG
        guard poll == nil,
              ProcessInfo.processInfo.environment["PLOZZ_SHOTS_NFS_HOST"] != nil,
              let directory = Self.directory
        else { return }

        let request = directory.appendingPathComponent(Self.requestFile)
        ackURL = directory.appendingPathComponent(Self.ackFile)
        // Polling rather than a `DispatchSource` file watcher: the host writes
        // the file by creating it, and a watcher has to be re-armed every time
        // its target is replaced. At this cadence the difference is not worth
        // the re-arming bug it would cost.
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

    public enum Request: Equatable, Sendable {
        /// Pop to the root of the Home stack.
        case home
        /// Push the detail page for the best match of `title`.
        case detail(title: String)
        /// Push the detail page, then the person page for `person` in its cast.
        case person(title: String, person: String)
        /// Push the library grid whose name best matches, or the first library.
        /// `sort` names a ``SortField`` — a library opened on its default
        /// alphabetical sort leads with whatever files sort before "A", which
        /// is not what the library looks like to use.
        case library(name: String?, sort: String?)
        /// Report what the library actually calls things matching `title`.
        /// Answered in the ack, so the shot list can be written against the
        /// names the library really has rather than the ones it ought to.
        case probe(title: String)
        /// Play the best match of `title`, starting `seconds` in.
        case play(title: String, seconds: Double)
    }

    // MARK: URL

    /// Parses `plozz://shots/<verb>?…`, returning `true` when the URL was ours.
    ///
    /// Returning a `Bool` rather than throwing keeps the caller —
    /// `AppState.handle(url:)` — able to fall through to the Top Shelf link
    /// parser for everything else.
    @discardableResult
    public func handle(url: URL) -> Bool {
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
            request = .library(name: query("name"), sort: query("sort"))
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
