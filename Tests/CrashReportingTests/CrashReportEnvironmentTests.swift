import XCTest
@testable import CrashReporting

/// Covers the rule that keeps the maintainer's own testing out of the real-crash
/// count, and the reporter lifecycle that rule depends on.
final class CrashReportEnvironmentTests: XCTestCase {
    // MARK: - Environment naming

    func testMaintainerDeviceGetsItsOwnEnvironment() {
        XCTAssertEqual(
            CrashReportContext.environmentName(base: "testflight", isMaintainerDevice: true),
            "testflight-dev"
        )
        XCTAssertEqual(
            CrashReportContext.environmentName(base: "production", isMaintainerDevice: true),
            "production-dev"
        )
    }

    /// The whole point: an ordinary tester's build must stay on the plain channel,
    /// or the separation is meaningless.
    func testOrdinaryDeviceKeepsThePlainChannel() {
        XCTAssertEqual(
            CrashReportContext.environmentName(base: "testflight", isMaintainerDevice: false),
            "testflight"
        )
        XCTAssertEqual(
            CrashReportContext.environmentName(base: "production", isMaintainerDevice: false),
            "production"
        )
    }

    /// A Debug build is already only ever the maintainer's, so suffixing it would
    /// give one thing two names and split its history.
    func testDebugIsNeverSuffixed() {
        XCTAssertEqual(
            CrashReportContext.environmentName(base: "debug", isMaintainerDevice: true),
            "debug"
        )
        XCTAssertEqual(
            CrashReportContext.environmentName(base: "debug", isMaintainerDevice: false),
            "debug"
        )
    }

    // MARK: - Context

    func testContextCarriesTheDeviceRoleTag() {
        let maintainer = CrashReportContext.make(
            bundleIdentifier: "com.thatcube.Plozz",
            version: "2026.8.26",
            build: "3322",
            providers: ["Plex"],
            isMaintainerDevice: true
        )
        XCTAssertEqual(maintainer.deviceRole, "maintainer")

        let user = CrashReportContext.make(
            bundleIdentifier: "com.thatcube.Plozz",
            version: "2026.8.26",
            build: "3322",
            providers: ["Plex"]
        )
        XCTAssertEqual(user.deviceRole, "user")
    }

    /// The release name is what separates a per-branch sideload from the real app
    /// in Sentry, so it must keep carrying the bundle id.
    func testReleaseNameIdentifiesTheBundle() {
        let context = CrashReportContext.make(
            bundleIdentifier: "com.thatcube.Plozz.my-branch",
            version: "2026.8.26",
            build: "3322",
            providers: []
        )
        XCTAssertEqual(context.releaseName, "com.thatcube.Plozz.my-branch@2026.8.26+3322")
        XCTAssertEqual(context.build, "3322")
    }

    // MARK: - Reporter lifecycle

    @MainActor
    private final class SpyReporter: CrashReporter {
        var isActive = false
        var starts: [String] = []
        var updates: [String] = []
        var stops = 0

        func start(context: CrashReportContext) {
            isActive = true
            starts.append(context.environment)
        }
        func update(context: CrashReportContext) { updates.append(context.environment) }
        func stop() {
            isActive = false
            stops += 1
        }
    }

    @MainActor
    private func context(_ environment: String) -> CrashReportContext {
        CrashReportContext(
            releaseName: "com.thatcube.Plozz@1+1",
            version: "1",
            build: "1",
            environment: environment,
            systemVersion: "tvOS 26.6",
            deviceModel: "AppleTV14,1",
            providers: ["Plex"]
        )
    }

    /// Sentry reads `options.environment` once, at `start`. Re-tagging the scope
    /// cannot move a running reporter between `testflight` and `testflight-dev`,
    /// so flipping the marker has to restart it — otherwise the toggle appears to
    /// work and silently does nothing until the next launch.
    @MainActor
    func testChangingEnvironmentRestartsTheReporter() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: true)

        controller.apply(enabled: true, context: context("testflight"))
        XCTAssertEqual(spy.starts, ["testflight"])
        XCTAssertEqual(spy.stops, 0)

        controller.apply(enabled: true, context: context("testflight-dev"))
        XCTAssertEqual(spy.stops, 1, "must stop before restarting on the new environment")
        XCTAssertEqual(spy.starts, ["testflight", "testflight-dev"])
    }

    /// An unchanged environment must NOT restart — a restart drops the session and
    /// is pure cost on every routine context refresh (accounts reloading, etc).
    @MainActor
    func testUnchangedEnvironmentOnlyUpdates() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: true)

        controller.apply(enabled: true, context: context("testflight"))
        controller.apply(enabled: true, context: context("testflight"))

        XCTAssertEqual(spy.starts, ["testflight"])
        XCTAssertEqual(spy.updates, ["testflight"])
        XCTAssertEqual(spy.stops, 0)
    }

    @MainActor
    func testOptOutStopsAndAllowsACleanRestart() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: true)

        controller.apply(enabled: true, context: context("production"))
        controller.apply(enabled: false, context: context("production"))
        XCTAssertEqual(spy.stops, 1)

        controller.apply(enabled: true, context: context("production"))
        XCTAssertEqual(spy.starts, ["production", "production"])
    }

    /// A build with no DSN must stay inert no matter what consent says.
    @MainActor
    func testUnconfiguredBuildNeverStarts() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: false)
        controller.apply(enabled: true, context: context("production"))
        XCTAssertTrue(spy.starts.isEmpty)
        XCTAssertFalse(spy.isActive)
    }
}
